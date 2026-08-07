//! 最长递增子序列(返回索引),MovableList diff 的最小移动集地基。
//!
//! 移植自 macro 内嵌 loro-mirror 的 `src/core/diff.ts`
//! `longestIncreasingSubsequence`(上游 loro-dev/loro-mirror, MIT)。
//! 测试照译自 `tests/core/lis.test.ts`,先于实现落地。

/// 蓝本用 `<` 做二分,语义是**严格递增**;相等元素只能留一个。
/// 返回的是输入序列的索引,不是值 —— diff 层要用索引把「留在原地的
/// 元素」和「需要 move 的元素」分开。
pub fn longest_increasing_subsequence<T: PartialOrd>(sequence: &[T]) -> Vec<usize> {
    let n = sequence.len();
    // 蓝本靠 JS 的 m[-1] === undefined 隐式处理空输入;Rust 里显式返回。
    if n == 0 {
        return Vec::new();
    }
    // p[i]:以 i 结尾的链中,i 的前驱索引。蓝本用 -1 表示无前驱;这里用
    // usize::MAX,且只在确认有前驱时才会被读到。
    let mut predecessor = vec![usize::MAX; n];
    // m[len]:长度为 len+1 的递增链中,结尾值最小的那条链的结尾索引。
    let mut tails: Vec<usize> = Vec::new();
    for i in 0..n {
        let x = &sequence[i];
        let mut low = 0;
        let mut high = tails.len();
        while low < high {
            let mid = (low + high) / 2;
            if sequence[tails[mid]] < *x {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        if low >= tails.len() {
            tails.push(i);
        } else {
            tails[low] = i;
        }
        if low > 0 {
            predecessor[i] = tails[low - 1];
        }
    }
    let mut lis = vec![0usize; tails.len()];
    let mut k = *tails.last().expect("n > 0 时 tails 非空");
    for slot in (0..lis.len()).rev() {
        lis[slot] = k;
        if slot > 0 {
            k = predecessor[k];
        }
    }
    lis
}

#[cfg(test)]
mod tests {
    use super::*;

    /// lis.test.ts: "should return empty array for empty input"
    #[test]
    fn empty_input_returns_empty() {
        assert_eq!(
            longest_increasing_subsequence::<i64>(&[]),
            Vec::<usize>::new()
        );
    }

    /// lis.test.ts: "should return the element itself for a single-element array"
    #[test]
    fn single_element_returns_its_index() {
        assert_eq!(longest_increasing_subsequence(&[5]), vec![0]);
    }

    /// lis.test.ts: "should find LIS in a sorted array"
    #[test]
    fn sorted_array_is_its_own_lis() {
        assert_eq!(
            longest_increasing_subsequence(&[1, 2, 3, 4, 5]),
            vec![0, 1, 2, 3, 4]
        );
    }

    /// lis.test.ts: "should find LIS in a reverse-sorted array"
    #[test]
    fn reverse_sorted_array_keeps_exactly_one() {
        let result = longest_increasing_subsequence(&[5, 4, 3, 2, 1]);
        assert_eq!(result.len(), 1);
        assert!((0..=4).contains(&result[0]));
    }

    /// lis.test.ts: "should find LIS in a random array"
    #[test]
    fn random_array_yields_strictly_increasing_values_of_length_five() {
        let sequence = [10, 22, 9, 33, 21, 50, 41, 60];
        let result = longest_increasing_subsequence(&sequence);
        let values: Vec<_> = result.iter().map(|&i| sequence[i]).collect();
        for pair in values.windows(2) {
            assert!(pair[1] > pair[0]);
        }
        // LIS 是 [10,22,33,50,60] 或 [10,22,33,41,60]
        assert_eq!(result.len(), 5);
    }

    /// lis.test.ts: "should handle sequences with duplicates"
    #[test]
    fn duplicates_collapse_to_a_strictly_increasing_chain() {
        let sequence = [1, 2, 2, 3, 1, 5];
        let result = longest_increasing_subsequence(&sequence);
        let values: Vec<_> = result.iter().map(|&i| sequence[i]).collect();
        for pair in values.windows(2) {
            assert!(pair[1] >= pair[0]);
        }
        // 应为长度 4(如 [1, 2, 3, 5])
        assert_eq!(result.len(), 4);
    }

    /// lis.test.ts: "should handle arrays with all identical elements"
    #[test]
    fn identical_elements_keep_exactly_one() {
        assert_eq!(longest_increasing_subsequence(&[7, 7, 7, 7]).len(), 1);
    }

    /// lis.test.ts: "should find the correct indices for a known LIS"
    #[test]
    fn known_sequence_yields_known_indices() {
        assert_eq!(
            longest_increasing_subsequence(&[3, 1, 8, 2, 5]),
            vec![1, 3, 4]
        );
    }

    /// lis.test.ts: "should handle non-consecutive increasing elements"
    #[test]
    fn non_consecutive_increasing_elements() {
        let sequence = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9];
        let result = longest_increasing_subsequence(&sequence);
        let values: Vec<_> = result.iter().map(|&i| sequence[i]).collect();
        for pair in values.windows(2) {
            assert!(pair[1] > pair[0]);
        }
        assert_eq!(result.len(), 4);
    }
}
