//! Mirror 本体:应用状态与 LoroDoc 的双向同步。
//!
//! 移植自 macro 内嵌 loro-mirror 的 `src/core/mirror.ts`。TS 的
//! `createStore`(state.ts)只是本类型的薄门面,不单独移植;immer reducer
//! 是 JS 生态件,不移植。
//!
//! 蓝本怪癖(照抄并钉死):
//!
//! 6. `updateMapEntry` 给容器字段插完子容器后**不 return**,紧接着的
//!    `map.set(key, value)` 又用纯值把同一个键盖掉 —— 根级 map 的直接
//!    更新路径(applyRootChanges → updateTopLevelContainer)最终落的是
//!    纯值。照抄。
//!
//! 语言差异与合理偏离(输出等价或蓝本行为系事故,逐条):
//!
//! - **同步世界**:蓝本的 `awaitMirrorSync`(连续三个微任务)是 JS 事件
//!   循环的产物;Rust 侧 loro 的事件在 commit 内同步派发,无需对应物。
//! - **订阅表**:蓝本 `containerSubscriptions.set` 覆盖旧条目时不调用旧的
//!   unsubscribe,旧订阅泄漏、事件重复派发(状态是整体重建,重复只浪费
//!   不出错)。Rust 的 `HashMap::insert` 返回旧 Subscription,drop 即退订
//!   —— 我们不刻意复刻泄漏。
//! - **updateListWithIdSelector 的现值比较**:蓝本拿容器 handler 与纯对象
//!   做 deepEqual,恒不等,于是已存在的容器项一律删了重插;这里把现值
//!   深读成 Value 再比较,内容相同时跳过重写。终态一致,op 更少。
//! - 重入防护:蓝本靠单线程 + `syncing` 布尔;这里 `syncing` 是原子量,
//!   回调先查它再拿锁,自己 commit 触发的同步回调因此不会死锁。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};

use loro::event::{Diff, ListDiffItem};
use loro::{
    Container, ContainerID, ContainerTrait, ContainerType, EventTriggerKind, LoroDoc, LoroList,
    LoroMap, LoroMovableList, LoroText, LoroValue, Subscription, ValueOrContainer,
};

use crate::change::{Change, ChangeKey, ChangeKind, InferContainerOptions};
use crate::diff::{diff_container, DiffError};
use crate::schema::{get_default_value, validate_schema, IdSelector, Schema};
use crate::utils::{is_value_of_container_type, try_infer_container_type};
use crate::value::{deep_equal, Value};

/// mirror.ts `SyncDirection`。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncDirection {
    FromLoro,
    ToLoro,
    Bidirectional,
}

/// mirror.ts `UpdateMetadata`。
#[derive(Debug, Clone)]
pub struct UpdateMetadata {
    pub direction: SyncDirection,
    pub tags: Option<Vec<String>>,
}

/// mirror.ts `SetStateOptions`。
#[derive(Debug, Clone, Default)]
pub struct SetStateOptions {
    pub tags: Option<Vec<String>>,
}

pub type SubscriberCallback = Arc<dyn Fn(&Value, &UpdateMetadata) + Send + Sync>;

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum MirrorError {
    #[error("Root schema must be of type \"schema\"")]
    RootSchemaNotRoot,
    #[error("State validation failed: {0}")]
    ValidationFailed(String),
    #[error(transparent)]
    Diff(#[from] DiffError),
    #[error("Unsupported change kind for map: {0}")]
    UnsupportedMapChange(String),
    #[error("Unsupported change kind for list: {0}")]
    UnsupportedListChange(String),
    #[error("Invalid list index")]
    InvalidListIndex,
    #[error("Failed to insert container")]
    ContainerInsertFailed(String),
    #[error("Unknown root container type")]
    UnknownRootContainerType,
    #[error("Text value must be a string")]
    TextValueNotString,
    #[error("List value must be an array")]
    ListValueNotArray,
    #[error("Map value must be an object")]
    MapValueNotObject,
}

/// mirror.ts `MirrorOptions`(doc 与 schema 单独传,其余在此)。
#[derive(Clone, Default)]
pub struct MirrorOptions {
    pub initial_state: Option<Value>,
    /// 默认 true。
    pub validate_updates: Option<bool>,
    pub infer_options: InferContainerOptions,
}

struct Registered {
    schema: Option<Arc<Schema>>,
}

struct Inner {
    doc: LoroDoc,
    schema: Option<Arc<Schema>>,
    validate_updates: bool,
    infer_options: InferContainerOptions,
    state: Mutex<Value>,
    syncing: AtomicBool,
    subscribers: Mutex<Vec<(u64, SubscriberCallback)>>,
    next_subscriber_id: Mutex<u64>,
    registry: Mutex<HashMap<ContainerID, Registered>>,
    container_subscriptions: Mutex<HashMap<ContainerID, Subscription>>,
    root_subscription: Mutex<Option<Subscription>>,
}

/// 双向镜像。克隆共享同一实例(蓝本的类实例语义)。
#[derive(Clone)]
pub struct Mirror {
    inner: Arc<Inner>,
}

/// `subscribe` 的回执,drop 即退订(蓝本返回 unsubscribe 闭包)。
pub struct MirrorSubscription {
    inner: Weak<Inner>,
    id: u64,
}

impl Drop for MirrorSubscription {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.upgrade() {
            inner
                .subscribers
                .lock()
                .unwrap()
                .retain(|(id, _)| *id != self.id);
        }
    }
}

// ---- Value ↔ LoroValue 转换 ----

fn json_to_loro(value: &Value) -> LoroValue {
    match value {
        Value::Null => LoroValue::Null,
        Value::Bool(b) => LoroValue::Bool(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                LoroValue::I64(i)
            } else {
                LoroValue::Double(n.as_f64().unwrap_or(0.0))
            }
        }
        Value::String(s) => LoroValue::String(s.clone().into()),
        Value::Array(items) => {
            LoroValue::List(items.iter().map(json_to_loro).collect::<Vec<_>>().into())
        }
        Value::Object(map) => LoroValue::Map(
            map.iter()
                .map(|(k, v)| (k.clone(), json_to_loro(v)))
                .collect(),
        ),
    }
}

fn loro_to_json(value: &LoroValue) -> Value {
    match value {
        LoroValue::Null => Value::Null,
        LoroValue::Bool(b) => Value::Bool(*b),
        LoroValue::Double(d) => serde_json::Number::from_f64(*d)
            .map(Value::Number)
            .unwrap_or(Value::Null),
        LoroValue::I64(i) => Value::Number((*i).into()),
        LoroValue::String(s) => Value::String(s.to_string()),
        LoroValue::List(items) => Value::Array(items.iter().map(loro_to_json).collect()),
        LoroValue::Map(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.to_string(), loro_to_json(v)))
                .collect(),
        ),
        // toJSON 展开一切子容器;deep value 不应出现 Container/Binary,
        // 兜底成可见字符串/字节数组,不 panic。
        LoroValue::Container(cid) => Value::String(cid.to_string()),
        LoroValue::Binary(bytes) => {
            Value::Array(bytes.iter().map(|b| Value::Number((*b).into())).collect())
        }
    }
}

fn value_or_container_to_json(item: &ValueOrContainer) -> Value {
    loro_to_json(&item.get_deep_value())
}

impl Mirror {
    /// mirror.ts `constructor`。
    pub fn new(
        doc: LoroDoc,
        schema: Option<Arc<Schema>>,
        options: MirrorOptions,
    ) -> Result<Self, MirrorError> {
        if let Some(schema) = &schema {
            if !matches!(schema.as_ref(), Schema::Root { .. }) {
                return Err(MirrorError::RootSchemaNotRoot);
            }
        }

        // 初始 state = schema 默认值 ⊕ initial_state(浅合并,蓝本展开语义)。
        let mut state = schema
            .as_deref()
            .and_then(get_default_value)
            .unwrap_or_else(|| Value::Object(serde_json::Map::new()));
        if let Some(initial) = &options.initial_state {
            shallow_assign(&mut state, initial);
        }

        let inner = Arc::new(Inner {
            doc,
            schema,
            validate_updates: options.validate_updates.unwrap_or(true),
            infer_options: options.infer_options,
            state: Mutex::new(state),
            syncing: AtomicBool::new(false),
            subscribers: Mutex::new(Vec::new()),
            next_subscriber_id: Mutex::new(0),
            registry: Mutex::new(HashMap::new()),
            container_subscriptions: Mutex::new(HashMap::new()),
            root_subscription: Mutex::new(None),
        });

        let mirror = Self { inner };
        mirror.initialize_containers();

        // 根订阅:处理 import 等全局更新。
        let weak = Arc::downgrade(&mirror.inner);
        let subscription = mirror.inner.doc.subscribe_root(Arc::new(move |event| {
            if let Some(inner) = weak.upgrade() {
                Mirror { inner }.handle_loro_event(&event);
            }
        }));
        *mirror.inner.root_subscription.lock().unwrap() = Some(subscription);

        Ok(mirror)
    }

    /// mirror.ts `initializeContainers`。
    fn initialize_containers(&self) {
        let inner = &self.inner;
        // 文档现状浅合并进 state。
        let doc_state = loro_to_json(&inner.doc.get_deep_value());
        {
            let mut state = inner.state.lock().unwrap();
            shallow_assign(&mut state, &doc_state);
        }

        // 注册 schema 声明的根容器。
        if let Some(Schema::Root { fields, .. }) = inner.schema.as_deref() {
            for (key, field_schema) in fields {
                let Some(container_type) = field_schema.container_type() else {
                    continue;
                };
                if let Some(cid) = crate::utils::root_container_id(&inner.doc, key, container_type)
                {
                    self.register_container(&cid, Some(field_schema.clone()));
                }
            }
        }
    }

    /// mirror.ts `registerContainer`:登记 + 订阅 + 递归子容器。
    fn register_container(&self, container_id: &ContainerID, schema: Option<Arc<Schema>>) {
        let inner = &self.inner;
        self.register_container_with_registry(container_id, schema.clone());

        let weak = Arc::downgrade(inner);
        let subscription = inner.doc.subscribe(
            container_id,
            Arc::new(move |event| {
                if let Some(inner) = weak.upgrade() {
                    Mirror { inner }.handle_container_event(&event);
                }
            }),
        );
        // 蓝本覆盖旧条目时泄漏旧订阅;这里 drop 旧的即退订(见模块注释)。
        inner
            .container_subscriptions
            .lock()
            .unwrap()
            .insert(container_id.clone(), subscription);

        self.register_nested_containers(container_id, schema);
    }

    /// mirror.ts `registerNestedContainers`:浅值里出现的子容器逐个登记。
    fn register_nested_containers(&self, container_id: &ContainerID, schema: Option<Arc<Schema>>) {
        let doc = &self.inner.doc;
        match container_id.container_type() {
            ContainerType::Map => {
                let map = doc.get_map(container_id.clone());
                if !map.is_attached() {
                    return;
                }
                if let LoroValue::Map(shallow) = map.get_value() {
                    for (key, value) in shallow.iter() {
                        if let LoroValue::Container(child_id) = value {
                            let child_schema = match schema.as_deref() {
                                Some(Schema::Map { fields, .. }) => {
                                    fields.get(key.as_str()).cloned()
                                }
                                _ => None,
                            };
                            self.register_container(child_id, child_schema);
                        }
                    }
                }
            }
            ContainerType::List | ContainerType::MovableList => {
                let shallow = if container_id.container_type() == ContainerType::List {
                    let list = doc.get_list(container_id.clone());
                    if !list.is_attached() {
                        return;
                    }
                    list.get_value()
                } else {
                    let list = doc.get_movable_list(container_id.clone());
                    if !list.is_attached() {
                        return;
                    }
                    list.get_value()
                };
                if let LoroValue::List(items) = shallow {
                    for value in items.iter() {
                        if let LoroValue::Container(child_id) = value {
                            let child_schema = match schema.as_deref() {
                                Some(Schema::List { item, .. })
                                | Some(Schema::MovableList { item, .. }) => item.get().cloned(),
                                _ => None,
                            };
                            self.register_container(child_id, child_schema);
                        }
                    }
                }
            }
            _ => {}
        }
    }

    /// mirror.ts `handleLoroEvent`(根订阅)。
    fn handle_loro_event(&self, event: &loro::event::DiffEvent) {
        let inner = &self.inner;
        if inner.syncing.load(Ordering::SeqCst) {
            return;
        }
        if event.origin == "to-loro" {
            return;
        }
        inner.syncing.store(true, Ordering::SeqCst);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let doc_state = loro_to_json(&inner.doc.get_deep_value());
            {
                let mut state = inner.state.lock().unwrap();
                shallow_assign(&mut state, &doc_state);
            }
            self.notify_subscribers(SyncDirection::FromLoro, None);
        }));
        self.register_containers_from_loro_event(event);
        inner.syncing.store(false, Ordering::SeqCst);
        if let Err(panic) = result {
            std::panic::resume_unwind(panic);
        }
    }

    /// mirror.ts `registerContainersFromLoroEvent`。
    fn register_containers_from_loro_event(&self, event: &loro::event::DiffEvent) {
        for container_diff in &event.events {
            match &container_diff.diff {
                Diff::List(items) => {
                    let schema = self.get_container_schema(container_diff.target);
                    for item in items {
                        let ListDiffItem::Insert { insert, .. } = item else {
                            continue;
                        };
                        for inserted in insert {
                            let ValueOrContainer::Container(container) = inserted else {
                                continue;
                            };
                            let item_schema = match schema.as_deref() {
                                Some(Schema::List { item, .. })
                                | Some(Schema::MovableList { item, .. }) => item.get().cloned(),
                                _ => None,
                            };
                            if item_schema.is_none() {
                                tracing::warn!(
                                    target = %container_diff.target,
                                    "Container schema not found for item in list"
                                );
                            }
                            self.register_container(&container.id(), item_schema);
                        }
                    }
                }
                Diff::Map(delta) => {
                    for (key, change) in delta.updated.iter() {
                        let Some(ValueOrContainer::Container(container)) = change else {
                            continue;
                        };
                        let child_schema = self
                            .get_schema_for_child(container_diff.target, key)
                            .filter(|schema| schema.is_container_schema());
                        if child_schema.is_none() {
                            tracing::warn!(
                                key = %key,
                                target = %container_diff.target,
                                "Container schema not found for key in map"
                            );
                        }
                        self.register_container(&container.id(), child_schema);
                    }
                }
                _ => {}
            }
        }
    }

    /// mirror.ts `handleContainerEvent`。
    fn handle_container_event(&self, event: &loro::event::DiffEvent) {
        let inner = &self.inner;
        if inner.syncing.load(Ordering::SeqCst) {
            return;
        }
        if event.origin == "to-loro" {
            return;
        }
        inner.syncing.store(true, Ordering::SeqCst);
        let doc_state = loro_to_json(&inner.doc.get_deep_value());
        {
            let mut state = inner.state.lock().unwrap();
            shallow_assign(&mut state, &doc_state);
        }
        // import 触发的由根订阅统一通知,避免双重派发。
        if event.triggered_by != EventTriggerKind::Import {
            self.notify_subscribers(SyncDirection::FromLoro, None);
        }
        inner.syncing.store(false, Ordering::SeqCst);
    }

    /// mirror.ts `updateLoro`:diff + apply(调用方负责 syncing 栅栏)。
    fn update_loro(&self, new_state: &Value) -> Result<(), MirrorError> {
        let inner = &self.inner;
        let current = inner.state.lock().unwrap().clone();
        let changes = diff_container(
            &inner.doc,
            &current,
            new_state,
            None,
            inner.schema.as_deref(),
            Some(inner.infer_options),
        )?;
        self.apply_changes_to_loro(changes)
    }

    /// mirror.ts `applyChangesToLoro`:按容器分组应用,统一以
    /// origin = "to-loro" 提交。
    fn apply_changes_to_loro(&self, changes: Vec<Change>) -> Result<(), MirrorError> {
        let inner = &self.inner;
        let mut by_container: Vec<(Option<ContainerID>, Vec<Change>)> = Vec::new();
        for change in changes {
            match by_container
                .iter_mut()
                .find(|(cid, _)| *cid == change.container)
            {
                Some((_, bucket)) => bucket.push(change),
                None => by_container.push((change.container.clone(), vec![change])),
            }
        }

        let result = (|| {
            for (container_id, container_changes) in by_container {
                match container_id {
                    None => self.apply_root_changes(container_changes)?,
                    Some(container_id) => {
                        self.apply_container_changes(&container_id, container_changes)?
                    }
                }
            }
            Ok(())
        })();

        inner
            .doc
            .commit_with(loro::CommitOptions::new().origin("to-loro"));
        result
    }

    /// mirror.ts `applyRootChanges`。
    fn apply_root_changes(&self, changes: Vec<Change>) -> Result<(), MirrorError> {
        let inner = &self.inner;
        for change in changes {
            let key = match &change.key {
                ChangeKey::Prop(key) => key.clone(),
                ChangeKey::Index(index) => index.to_string(),
            };
            let field_schema = match inner.schema.as_deref() {
                Some(Schema::Root { fields, .. }) => fields.get(&key).cloned(),
                _ => None,
            };
            let container_type = field_schema
                .as_deref()
                .and_then(Schema::container_type)
                .or_else(|| {
                    change
                        .value
                        .as_ref()
                        .and_then(|v| try_infer_container_type(v, Some(inner.infer_options)))
                });
            let Some(container_type) = container_type else {
                return Err(MirrorError::UnknownRootContainerType);
            };
            let Some(cid) = crate::utils::root_container_id(&inner.doc, &key, container_type)
            else {
                return Err(MirrorError::UnknownRootContainerType);
            };
            self.register_container_with_registry(&cid, field_schema);
            let value = change.value.clone().unwrap_or(Value::Null);
            self.update_top_level_container(&cid, &value)?;
        }
        Ok(())
    }

    /// mirror.ts `applyContainerChanges`。
    fn apply_container_changes(
        &self,
        container_id: &ContainerID,
        changes: Vec<Change>,
    ) -> Result<(), MirrorError> {
        let doc = &self.inner.doc;
        match container_id.container_type() {
            ContainerType::Map => {
                let map = doc.get_map(container_id.clone());
                for change in changes {
                    let ChangeKey::Prop(key) = &change.key else {
                        continue;
                    };
                    if key.is_empty() {
                        continue; // 蓝本跳过空键
                    }
                    match &change.kind {
                        ChangeKind::Insert => {
                            let value = change.value.clone().unwrap_or(Value::Null);
                            map.insert(key, json_to_loro(&value))
                                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                        }
                        ChangeKind::InsertContainer { .. } => {
                            let schema = self.get_schema_for_child_container(container_id, key);
                            let value = change.value.clone().unwrap_or(Value::Null);
                            self.insert_container_into_map(&map, schema, key, &value)?;
                        }
                        ChangeKind::Delete => {
                            map.delete(key)
                                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                        }
                        other => {
                            return Err(MirrorError::UnsupportedMapChange(format!("{other:?}")))
                        }
                    }
                }
            }
            ContainerType::List => {
                let list = doc.get_list(container_id.clone());
                for change in changes {
                    let ChangeKey::Index(index) = change.key else {
                        return Err(MirrorError::InvalidListIndex);
                    };
                    match &change.kind {
                        ChangeKind::Delete => {
                            list.delete(index, 1)
                                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                        }
                        ChangeKind::Insert => {
                            let value = change.value.clone().unwrap_or(Value::Null);
                            list.insert(index, json_to_loro(&value))
                                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                        }
                        ChangeKind::InsertContainer { .. } => {
                            let schema = self.get_schema_for_child_container_index(container_id);
                            let value = change.value.clone().unwrap_or(Value::Null);
                            self.insert_container_into_list(
                                &ListHandle::List(list.clone()),
                                schema,
                                index,
                                &value,
                            )?;
                        }
                        other => {
                            return Err(MirrorError::UnsupportedListChange(format!("{other:?}")))
                        }
                    }
                }
            }
            ContainerType::MovableList => {
                let list = doc.get_movable_list(container_id.clone());
                for change in changes {
                    let ChangeKey::Index(index) = change.key else {
                        return Err(MirrorError::InvalidListIndex);
                    };
                    match &change.kind {
                        ChangeKind::Delete => {
                            list.delete(index, 1)
                                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                        }
                        ChangeKind::Insert => {
                            let value = change.value.clone().unwrap_or(Value::Null);
                            list.insert(index, json_to_loro(&value))
                                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                        }
                        ChangeKind::InsertContainer { .. } => {
                            let schema = self.get_schema_for_child_container_index(container_id);
                            let value = change.value.clone().unwrap_or(Value::Null);
                            self.insert_container_into_list(
                                &ListHandle::Movable(list.clone()),
                                schema,
                                index,
                                &value,
                            )?;
                        }
                        ChangeKind::Move {
                            from_index,
                            to_index,
                        } => {
                            list.mov(*from_index, *to_index)
                                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                        }
                    }
                }
            }
            ContainerType::Text => {
                let text = doc.get_text(container_id.clone());
                for change in changes {
                    match &change.value {
                        Some(Value::String(s)) => {
                            text.update(s, loro::UpdateOptions::default())
                                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                        }
                        other => {
                            tracing::warn!(
                                ?other,
                                "Invalid Text change. Only 'value' property can be updated"
                            );
                        }
                    }
                }
            }
            other => {
                tracing::warn!(?other, "Unsupported container type");
            }
        }
        Ok(())
    }

    /// mirror.ts `updateTopLevelContainer`。
    fn update_top_level_container(
        &self,
        container_id: &ContainerID,
        value: &Value,
    ) -> Result<(), MirrorError> {
        let doc = &self.inner.doc;
        match container_id.container_type() {
            ContainerType::Text => {
                let Value::String(s) = value else {
                    return Err(MirrorError::TextValueNotString);
                };
                doc.get_text(container_id.clone())
                    .update(s, loro::UpdateOptions::default())
                    .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))
            }
            ContainerType::List => self.update_list_container(
                &ListHandle::List(doc.get_list(container_id.clone())),
                container_id,
                value,
            ),
            ContainerType::MovableList => self.update_list_container(
                &ListHandle::Movable(doc.get_movable_list(container_id.clone())),
                container_id,
                value,
            ),
            ContainerType::Map => self.update_map_container(container_id, value),
            _ => Err(MirrorError::UnknownRootContainerType),
        }
    }

    /// mirror.ts `updateListContainer`。
    fn update_list_container(
        &self,
        list: &ListHandle,
        container_id: &ContainerID,
        value: &Value,
    ) -> Result<(), MirrorError> {
        let Value::Array(new_items) = value else {
            return Err(MirrorError::ListValueNotArray);
        };
        let schema = self.get_container_schema(container_id);
        let (id_selector, item_schema): (Option<IdSelector>, Option<Arc<Schema>>) =
            match schema.as_deref() {
                Some(Schema::List {
                    item, id_selector, ..
                })
                | Some(Schema::MovableList {
                    item, id_selector, ..
                }) => (id_selector.clone(), item.get().cloned()),
                _ => (None, None),
            };
        if let Some(id_selector) = id_selector {
            self.update_list_with_id_selector(list, new_items, &id_selector, item_schema)
        } else {
            self.update_list_by_index(list, new_items, item_schema)
        }
    }

    /// mirror.ts `updateListWithIdSelector`。现值深读后比较(见模块注释)。
    fn update_list_with_id_selector(
        &self,
        list: &ListHandle,
        new_items: &[Value],
        id_selector: &IdSelector,
        item_schema: Option<Arc<Schema>>,
    ) -> Result<(), MirrorError> {
        let mut current_ids: HashMap<String, usize> = HashMap::new();
        for i in 0..list.len() {
            if let Some(item) = list.get(i) {
                let value = value_or_container_to_json(&item);
                if let Some(id) = id_selector(&value).filter(|id| !id.is_empty()) {
                    current_ids.insert(id, i);
                }
            }
        }

        let new_ids: std::collections::HashSet<String> = new_items
            .iter()
            .filter_map(|item| id_selector(item).filter(|id| !id.is_empty()))
            .collect();

        // 旧有新无 → 降序删除。
        let mut to_remove: Vec<usize> = current_ids
            .iter()
            .filter(|(id, _)| !new_ids.contains(*id))
            .map(|(_, &index)| index)
            .collect();
        to_remove.sort_unstable_by(|a, b| b.cmp(a));
        for index in to_remove {
            list.delete(index, 1)?;
        }

        // 重建 current 映射已失效;蓝本沿用旧索引游标逐项对齐。
        let mut current_index: usize = 0;
        for new_item in new_items {
            let Some(id) = id_selector(new_item).filter(|id| !id.is_empty()) else {
                continue;
            };
            if current_ids.contains_key(&id) {
                let current_item = list
                    .get(current_index)
                    .map(|v| value_or_container_to_json(&v));
                if current_item.as_ref() != Some(new_item)
                    && !current_item
                        .as_ref()
                        .is_some_and(|current| deep_equal(current, new_item))
                {
                    list.delete(current_index, 1)?;
                    self.insert_item_into_list(list, current_index, new_item, item_schema.clone())?;
                }
            } else {
                self.insert_item_into_list(list, current_index, new_item, item_schema.clone())?;
            }
            current_index += 1;
        }

        // 截断多余尾部。
        if current_index < list.len() {
            let excess = list.len() - current_index;
            list.delete(current_index, excess)?;
        }
        Ok(())
    }

    /// mirror.ts `updateListByIndex`。
    fn update_list_by_index(
        &self,
        list: &ListHandle,
        new_items: &[Value],
        item_schema: Option<Arc<Schema>>,
    ) -> Result<(), MirrorError> {
        let old_length = list.len();
        let max_length = old_length.max(new_items.len());
        let mut i = 0;
        while i < max_length {
            if i >= old_length {
                self.insert_item_into_list(list, i, &new_items[i], item_schema.clone())?;
            } else if i >= new_items.len() {
                list.delete(new_items.len(), old_length - new_items.len())?;
                break;
            } else {
                let old_item = list.get(i).map(|v| value_or_container_to_json(&v));
                if !old_item
                    .as_ref()
                    .is_some_and(|old| deep_equal(old, &new_items[i]))
                {
                    list.delete(i, 1)?;
                    self.insert_item_into_list(list, i, &new_items[i], item_schema.clone())?;
                }
            }
            i += 1;
        }
        Ok(())
    }

    /// mirror.ts `insertItemIntoList`。
    fn insert_item_into_list(
        &self,
        list: &ListHandle,
        index: usize,
        item: &Value,
        item_schema: Option<Arc<Schema>>,
    ) -> Result<(), MirrorError> {
        let (is_container, container_schema) = match &item_schema {
            Some(schema) if schema.is_container_schema() => (true, Some(schema.clone())),
            _ => (
                try_infer_container_type(item, Some(self.inner.infer_options)).is_some(),
                None,
            ),
        };
        if is_container && matches!(item, Value::Object(_) | Value::Array(_)) {
            return self.insert_container_into_list(list, container_schema, index, item);
        }
        list.insert(index, json_to_loro(item))
    }

    /// mirror.ts `insertContainerIntoMap` + `createContainerFromSchema`。
    fn insert_container_into_map(
        &self,
        map: &LoroMap,
        schema: Option<Arc<Schema>>,
        key: &str,
        value: &Value,
    ) -> Result<(), MirrorError> {
        let container_type = schema
            .as_deref()
            .and_then(Schema::container_type)
            .or_else(|| try_infer_container_type(value, Some(self.inner.infer_options)))
            .ok_or(MirrorError::UnknownRootContainerType)?;

        let inserted: Container = match container_type {
            ContainerType::Map => map
                .insert_container(key, LoroMap::new())
                .map(Container::Map),
            ContainerType::List => map
                .insert_container(key, LoroList::new())
                .map(Container::List),
            ContainerType::MovableList => map
                .insert_container(key, LoroMovableList::new())
                .map(Container::MovableList),
            ContainerType::Text => map
                .insert_container(key, LoroText::new())
                .map(Container::Text),
            _ => return Err(MirrorError::UnknownRootContainerType),
        }
        .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;

        self.register_container(&inserted.id(), schema.clone());
        self.initialize_container(&inserted, container_type, schema, value)
    }

    /// mirror.ts `insertContainerIntoList` + `createContainerFromSchema`。
    fn insert_container_into_list(
        &self,
        list: &ListHandle,
        schema: Option<Arc<Schema>>,
        index: usize,
        value: &Value,
    ) -> Result<(), MirrorError> {
        let container_type = schema
            .as_deref()
            .and_then(Schema::container_type)
            .or_else(|| try_infer_container_type(value, Some(self.inner.infer_options)))
            .ok_or(MirrorError::UnknownRootContainerType)?;

        let inserted = list.insert_container(index, container_type)?;
        self.register_container(&inserted.id(), schema.clone());
        self.initialize_container(&inserted, container_type, schema, value)
    }

    /// mirror.ts `initializeContainer`:建好的容器按 schema 灌初值。
    fn initialize_container(
        &self,
        container: &Container,
        container_type: ContainerType,
        schema: Option<Arc<Schema>>,
        value: &Value,
    ) -> Result<(), MirrorError> {
        match container_type {
            ContainerType::Map => {
                let Container::Map(map) = container else {
                    return Ok(());
                };
                let Value::Object(entries) = value else {
                    return Ok(());
                };
                for (key, val) in entries {
                    let field_schema = match schema.as_deref() {
                        Some(Schema::Map { fields, .. }) => fields.get(key).cloned(),
                        _ => None,
                    };
                    let is_field_container = field_schema
                        .as_deref()
                        .is_some_and(Schema::is_container_schema);
                    let matches_type = field_schema
                        .as_deref()
                        .and_then(Schema::container_type)
                        .is_some_and(|t| is_value_of_container_type(t, val));
                    if is_field_container && matches_type {
                        self.insert_container_into_map(map, field_schema, key, val)?;
                    } else {
                        map.insert(key, json_to_loro(val))
                            .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                    }
                }
                Ok(())
            }
            ContainerType::List | ContainerType::MovableList => {
                let handle = match container {
                    Container::List(list) => ListHandle::List(list.clone()),
                    Container::MovableList(list) => ListHandle::Movable(list.clone()),
                    _ => return Ok(()),
                };
                let Value::Array(items) = value else {
                    return Ok(());
                };
                let item_schema = match schema.as_deref() {
                    Some(Schema::List { item, .. }) | Some(Schema::MovableList { item, .. }) => {
                        item.get().cloned()
                    }
                    _ => None,
                };
                let is_item_container = item_schema
                    .as_deref()
                    .is_some_and(Schema::is_container_schema);
                for (i, item) in items.iter().enumerate() {
                    let matches_type = item_schema
                        .as_deref()
                        .and_then(Schema::container_type)
                        .is_some_and(|t| is_value_of_container_type(t, item));
                    if is_item_container && matches_type {
                        self.insert_container_into_list(&handle, item_schema.clone(), i, item)?;
                    } else {
                        handle.insert(i, json_to_loro(item))?;
                    }
                }
                Ok(())
            }
            ContainerType::Text => {
                let Container::Text(text) = container else {
                    return Ok(());
                };
                if let Value::String(s) = value {
                    text.update(s, loro::UpdateOptions::default())
                        .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
                }
                Ok(())
            }
            _ => Err(MirrorError::UnknownRootContainerType),
        }
    }

    /// mirror.ts `updateMapContainer`。
    fn update_map_container(
        &self,
        container_id: &ContainerID,
        value: &Value,
    ) -> Result<(), MirrorError> {
        let Value::Object(entries) = value else {
            return Err(MirrorError::MapValueNotObject);
        };
        let schema = self.get_container_schema(container_id);
        let Some(schema) = schema.filter(|s| matches!(s.as_ref(), Schema::Map { .. })) else {
            tracing::warn!(container = %container_id, "No valid schema found for map");
            return Ok(());
        };
        let map = self.inner.doc.get_map(container_id.clone());

        let mut current_keys: std::collections::HashSet<String> = match map.get_value() {
            LoroValue::Map(shallow) => shallow.keys().map(|k| k.to_string()).collect(),
            _ => Default::default(),
        };

        for (key, val) in entries {
            self.update_map_entry(&map, key, val, &schema)?;
            current_keys.remove(key);
        }
        for key in current_keys {
            map.delete(&key)
                .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))?;
        }
        Ok(())
    }

    /// mirror.ts `updateMapEntry`。
    ///
    /// 蓝本怪癖 6:容器分支插完子容器后不 return,末尾的 `map.set` 又把
    /// 同键盖成纯值。照抄。
    fn update_map_entry(
        &self,
        map: &LoroMap,
        key: &str,
        value: &Value,
        schema: &Arc<Schema>,
    ) -> Result<(), MirrorError> {
        if let Schema::Map { fields, .. } = schema.as_ref() {
            if let Some(field_schema) = fields.get(key) {
                // 蓝本的容器判定漏了 movable-list,照抄。
                let is_container = matches!(
                    field_schema.as_ref(),
                    Schema::Map { .. } | Schema::List { .. } | Schema::Text(_)
                );
                if is_container && matches!(value, Value::Object(_) | Value::Array(_)) {
                    self.insert_container_into_map(map, Some(field_schema.clone()), key, value)?;
                }
            }
        }
        map.insert(key, json_to_loro(value))
            .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))
    }

    // ---- 公共 API ----

    /// mirror.ts `getState`。
    pub fn get_state(&self) -> Value {
        self.inner.state.lock().unwrap().clone()
    }

    pub fn doc(&self) -> &LoroDoc {
        &self.inner.doc
    }

    /// mirror.ts `subscribe`。
    pub fn subscribe(&self, callback: SubscriberCallback) -> MirrorSubscription {
        let mut next = self.inner.next_subscriber_id.lock().unwrap();
        let id = *next;
        *next += 1;
        drop(next);
        self.inner.subscribers.lock().unwrap().push((id, callback));
        MirrorSubscription {
            inner: Arc::downgrade(&self.inner),
            id,
        }
    }

    fn notify_subscribers(&self, direction: SyncDirection, tags: Option<Vec<String>>) {
        let metadata = UpdateMetadata { direction, tags };
        let state = self.inner.state.lock().unwrap().clone();
        let subscribers: Vec<SubscriberCallback> = self
            .inner
            .subscribers
            .lock()
            .unwrap()
            .iter()
            .map(|(_, cb)| cb.clone())
            .collect();
        for subscriber in subscribers {
            subscriber(&state, &metadata);
        }
    }

    /// mirror.ts `setState`。
    pub fn set_state(
        &self,
        updater: impl FnOnce(&Value) -> Value,
        options: SetStateOptions,
    ) -> Result<(), MirrorError> {
        let inner = &self.inner;
        if inner.syncing.load(Ordering::SeqCst) {
            return Ok(()); // 蓝本静默忽略重入
        }
        let new_state = {
            let state = inner.state.lock().unwrap();
            updater(&state)
        };

        if inner.validate_updates {
            if let Some(schema) = inner.schema.as_deref() {
                if let Err(errors) = validate_schema(schema, Some(&new_state)) {
                    return Err(MirrorError::ValidationFailed(errors.join(", ")));
                }
            }
        }

        inner.syncing.store(true, Ordering::SeqCst);
        let result = self.update_loro(&new_state);
        inner.syncing.store(false, Ordering::SeqCst);
        result?;

        *inner.state.lock().unwrap() = new_state;
        self.notify_subscribers(SyncDirection::ToLoro, options.tags);
        Ok(())
    }

    /// setState 的合并式便利形态(蓝本的对象参数形态)。
    pub fn set_state_merge(&self, partial: &Value) -> Result<(), MirrorError> {
        let partial = partial.clone();
        self.set_state(
            move |state| {
                let mut next = state.clone();
                shallow_assign(&mut next, &partial);
                next
            },
            SetStateOptions::default(),
        )
    }

    /// mirror.ts `syncFromLoro`。
    pub fn sync_from_loro(&self) -> Value {
        let inner = &self.inner;
        if inner.syncing.load(Ordering::SeqCst) {
            return self.get_state();
        }
        inner.syncing.store(true, Ordering::SeqCst);
        let doc_state = loro_to_json(&inner.doc.get_deep_value());
        {
            let mut state = inner.state.lock().unwrap();
            shallow_assign(&mut state, &doc_state);
        }
        self.notify_subscribers(SyncDirection::FromLoro, None);
        inner.syncing.store(false, Ordering::SeqCst);
        self.get_state()
    }

    /// mirror.ts `syncToLoro`。
    pub fn sync_to_loro(&self) -> Result<(), MirrorError> {
        let inner = &self.inner;
        if inner.syncing.load(Ordering::SeqCst) {
            return Ok(());
        }
        inner.syncing.store(true, Ordering::SeqCst);
        let state = self.get_state();
        let result = self.update_loro(&state);
        inner.syncing.store(false, Ordering::SeqCst);
        result?;
        self.notify_subscribers(SyncDirection::ToLoro, None);
        Ok(())
    }

    /// mirror.ts `sync`。
    pub fn sync(&self) -> Result<Value, MirrorError> {
        self.sync_from_loro();
        self.sync_to_loro()?;
        Ok(self.get_state())
    }

    /// mirror.ts `getContainerIds`。
    pub fn container_ids(&self) -> Vec<ContainerID> {
        self.inner
            .registry
            .lock()
            .unwrap()
            .keys()
            .cloned()
            .collect()
    }

    // ---- registry ----

    fn register_container_with_registry(
        &self,
        container_id: &ContainerID,
        schema: Option<Arc<Schema>>,
    ) {
        self.inner
            .registry
            .lock()
            .unwrap()
            .insert(container_id.clone(), Registered { schema });
    }

    fn get_container_schema(&self, container_id: &ContainerID) -> Option<Arc<Schema>> {
        self.inner
            .registry
            .lock()
            .unwrap()
            .get(container_id)
            .and_then(|r| r.schema.clone())
    }

    fn get_schema_for_child(
        &self,
        container_id: &ContainerID,
        child_key: &str,
    ) -> Option<Arc<Schema>> {
        let schema = self.get_container_schema(container_id)?;
        match schema.as_ref() {
            Schema::Map { fields, .. } => fields.get(child_key).cloned(),
            Schema::List { item, .. } | Schema::MovableList { item, .. } => item.get().cloned(),
            _ => None,
        }
    }

    fn get_schema_for_child_container(
        &self,
        container_id: &ContainerID,
        child_key: &str,
    ) -> Option<Arc<Schema>> {
        self.get_schema_for_child(container_id, child_key)
            .filter(|schema| schema.is_container_schema())
    }

    fn get_schema_for_child_container_index(
        &self,
        container_id: &ContainerID,
    ) -> Option<Arc<Schema>> {
        let schema = self.get_container_schema(container_id)?;
        match schema.as_ref() {
            Schema::List { item, .. } | Schema::MovableList { item, .. } => item
                .get()
                .cloned()
                .filter(|schema| schema.is_container_schema()),
            _ => None,
        }
    }
}

/// List 与 MovableList 的公共操作面,蓝本靠 TS 结构化类型免费获得。
enum ListHandle {
    List(LoroList),
    Movable(LoroMovableList),
}

impl ListHandle {
    fn len(&self) -> usize {
        match self {
            Self::List(list) => list.len(),
            Self::Movable(list) => list.len(),
        }
    }

    fn get(&self, index: usize) -> Option<ValueOrContainer> {
        match self {
            Self::List(list) => list.get(index),
            Self::Movable(list) => list.get(index),
        }
    }

    fn insert(&self, index: usize, value: LoroValue) -> Result<(), MirrorError> {
        match self {
            Self::List(list) => list.insert(index, value),
            Self::Movable(list) => list.insert(index, value),
        }
        .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))
    }

    fn delete(&self, index: usize, len: usize) -> Result<(), MirrorError> {
        match self {
            Self::List(list) => list.delete(index, len),
            Self::Movable(list) => list.delete(index, len),
        }
        .map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))
    }

    fn insert_container(
        &self,
        index: usize,
        container_type: ContainerType,
    ) -> Result<Container, MirrorError> {
        let result = match (self, container_type) {
            (Self::List(list), ContainerType::Map) => list
                .insert_container(index, LoroMap::new())
                .map(Container::Map),
            (Self::List(list), ContainerType::List) => list
                .insert_container(index, LoroList::new())
                .map(Container::List),
            (Self::List(list), ContainerType::MovableList) => list
                .insert_container(index, LoroMovableList::new())
                .map(Container::MovableList),
            (Self::List(list), ContainerType::Text) => list
                .insert_container(index, LoroText::new())
                .map(Container::Text),
            (Self::Movable(list), ContainerType::Map) => list
                .insert_container(index, LoroMap::new())
                .map(Container::Map),
            (Self::Movable(list), ContainerType::List) => list
                .insert_container(index, LoroList::new())
                .map(Container::List),
            (Self::Movable(list), ContainerType::MovableList) => list
                .insert_container(index, LoroMovableList::new())
                .map(Container::MovableList),
            (Self::Movable(list), ContainerType::Text) => list
                .insert_container(index, LoroText::new())
                .map(Container::Text),
            _ => return Err(MirrorError::UnknownRootContainerType),
        };
        result.map_err(|e| MirrorError::ContainerInsertFailed(e.to_string()))
    }
}

/// `Object.assign(draft, source)` 的浅合并:蓝本用它把文档状态盖进 app
/// 状态,root 上不在文档里的键(如 Ignore 字段)得以保留。
fn shallow_assign(target: &mut Value, source: &Value) {
    let Value::Object(source_map) = source else {
        return;
    };
    if !matches!(target, Value::Object(_)) {
        *target = Value::Object(serde_json::Map::new());
    }
    let Value::Object(target_map) = target else {
        unreachable!()
    };
    for (key, value) in source_map {
        target_map.insert(key.clone(), value.clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn todo_schema() -> Arc<Schema> {
        let selector: IdSelector = Arc::new(|item: &Value| {
            item.get("id")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
        });
        Schema::root([(
            "todos",
            Schema::movable_list_keyed(
                Schema::map([
                    ("id", Schema::string()),
                    ("text", Schema::string()),
                    ("done", Schema::boolean()),
                ]),
                selector,
            ),
        )])
    }

    // ---- state.test.ts describe("createStore") 的核心用例 ----

    /// state.test.ts "should create a store with default values"
    #[test]
    fn creates_with_schema_defaults() {
        let schema = Schema::root([(
            "meta",
            Schema::map([(
                "title",
                Schema::string_with(crate::schema::SchemaOptions::required()),
            )]),
        )]);
        let mirror = Mirror::new(LoroDoc::new(), Some(schema), MirrorOptions::default()).unwrap();
        assert_eq!(mirror.get_state(), json!({"meta": {"title": ""}}));
    }

    /// state.test.ts "should create a store with initial values"
    #[test]
    fn initial_state_overrides_defaults() {
        let mirror = Mirror::new(
            LoroDoc::new(),
            Some(todo_schema()),
            MirrorOptions {
                initial_state: Some(json!({"todos": [{"id": "1", "text": "港", "done": false}]})),
                ..MirrorOptions::default()
            },
        )
        .unwrap();
        assert_eq!(mirror.get_state()["todos"][0]["text"], json!("港"));
    }

    /// state.test.ts "should update state with setState" +
    /// mirror.test.ts 的 to-Loro 断言:setState 后文档本身要有数据。
    #[test]
    fn set_state_writes_through_to_loro() {
        let doc = LoroDoc::new();
        let mirror =
            Mirror::new(doc.clone(), Some(todo_schema()), MirrorOptions::default()).unwrap();
        mirror
            .set_state_merge(&json!({"todos": [{"id": "a", "text": "写完", "done": false}]}))
            .unwrap();

        let doc_json = loro_to_json(&doc.get_deep_value());
        assert_eq!(doc_json["todos"][0]["id"], json!("a"));
        assert_eq!(doc_json["todos"][0]["text"], json!("写完"));
    }

    /// state.test.ts "should sync state bidirectionally":对端 import 的
    /// 更新要反映进本地 state。
    #[test]
    fn imported_updates_flow_back_into_state() {
        let doc_a = LoroDoc::new();
        let mirror_a =
            Mirror::new(doc_a.clone(), Some(todo_schema()), MirrorOptions::default()).unwrap();
        mirror_a
            .set_state_merge(&json!({"todos": [{"id": "a", "text": "原文", "done": false}]}))
            .unwrap();

        let doc_b = LoroDoc::new();
        let mirror_b =
            Mirror::new(doc_b.clone(), Some(todo_schema()), MirrorOptions::default()).unwrap();
        doc_b
            .import(&doc_a.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        assert_eq!(mirror_b.get_state()["todos"][0]["text"], json!("原文"));
    }

    /// state.test.ts "should subscribe to state changes"
    #[test]
    fn subscribers_see_to_loro_updates() {
        let mirror = Mirror::new(
            LoroDoc::new(),
            Some(todo_schema()),
            MirrorOptions::default(),
        )
        .unwrap();
        let seen: Arc<Mutex<Vec<SyncDirection>>> = Arc::new(Mutex::new(Vec::new()));
        let seen_in_callback = seen.clone();
        let _subscription = mirror.subscribe(Arc::new(move |_, metadata| {
            seen_in_callback.lock().unwrap().push(metadata.direction);
        }));
        mirror
            .set_state_merge(&json!({"todos": [{"id": "a", "text": "x", "done": false}]}))
            .unwrap();
        assert_eq!(seen.lock().unwrap().as_slice(), &[SyncDirection::ToLoro]);
    }

    /// setState 的校验失败必须大声(蓝本 throw)。
    #[test]
    fn invalid_set_state_is_refused() {
        let mirror = Mirror::new(
            LoroDoc::new(),
            Some(todo_schema()),
            MirrorOptions::default(),
        )
        .unwrap();
        let result = mirror.set_state_merge(&json!({"unknown_field": 1}));
        assert!(matches!(result, Err(MirrorError::ValidationFailed(_))));
    }

    /// mirror-movable-list.test.ts 的核心:重排通过 move 收敛,item 的
    /// 容器身份不变。
    #[test]
    fn movable_reorder_round_trips() {
        let doc = LoroDoc::new();
        let mirror =
            Mirror::new(doc.clone(), Some(todo_schema()), MirrorOptions::default()).unwrap();
        mirror
            .set_state_merge(&json!({"todos": [
                {"id": "a", "text": "一", "done": false},
                {"id": "b", "text": "二", "done": false},
                {"id": "c", "text": "三", "done": false},
            ]}))
            .unwrap();
        // c 提到最前
        mirror
            .set_state_merge(&json!({"todos": [
                {"id": "c", "text": "三", "done": false},
                {"id": "a", "text": "一", "done": false},
                {"id": "b", "text": "二", "done": false},
            ]}))
            .unwrap();
        let doc_json = loro_to_json(&doc.get_deep_value());
        let ids: Vec<_> = doc_json["todos"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["id"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(ids, vec!["c", "a", "b"]);
    }

    /// mirror-text.test.ts 的核心:LoroText 字段以文本容器落地,更新走
    /// text.update。
    #[test]
    fn text_fields_land_in_text_containers() {
        let schema = Schema::root([("note", Schema::map([("body", Schema::text())]))]);
        let doc = LoroDoc::new();
        let mirror = Mirror::new(doc.clone(), Some(schema), MirrorOptions::default()).unwrap();
        mirror
            .set_state_merge(&json!({"note": {"body": "第一版"}}))
            .unwrap();
        mirror
            .set_state_merge(&json!({"note": {"body": "第二版"}}))
            .unwrap();

        let note = doc.get_map("note");
        let Some(ValueOrContainer::Container(Container::Text(text))) = note.get("body") else {
            panic!("body 应当是 LoroText 容器");
        };
        assert_eq!(text.to_string(), "第二版");
    }

    /// 两个镜像经由各自文档互相合并后收敛到同一状态。
    #[test]
    fn two_mirrors_converge_after_exchange() {
        let doc_a = LoroDoc::new();
        let doc_b = LoroDoc::new();
        let mirror_a =
            Mirror::new(doc_a.clone(), Some(todo_schema()), MirrorOptions::default()).unwrap();
        let mirror_b =
            Mirror::new(doc_b.clone(), Some(todo_schema()), MirrorOptions::default()).unwrap();

        mirror_a
            .set_state_merge(&json!({"todos": [{"id": "a", "text": "甲", "done": false}]}))
            .unwrap();
        doc_b
            .import(&doc_a.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();
        mirror_b
            .set_state_merge(&json!({"todos": [
                {"id": "a", "text": "甲", "done": false},
                {"id": "b", "text": "乙", "done": false},
            ]}))
            .unwrap();
        doc_a
            .import(&doc_b.export(loro::ExportMode::Snapshot).unwrap())
            .unwrap();

        assert_eq!(mirror_a.get_state(), mirror_b.get_state());
        assert_eq!(mirror_a.get_state()["todos"].as_array().unwrap().len(), 2);
    }
}
