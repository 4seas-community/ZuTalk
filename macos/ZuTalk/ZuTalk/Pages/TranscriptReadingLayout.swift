// TranscriptReadingLayout.swift
// 并排对照 / 只看原话:一个选择,两处可以选。
//
// 录音中,这个选择在录音条的「⋯」里,好让录音页只剩文字;录完以后,它是
// 文字稿上方那个分段控件。两处都写到这里,文字稿也从这里读,所以不会各说
// 各的。
//
// 它是「怎么看」,不是设置:按主题记,只记到这次运行结束 —— 以前记在文字稿
// 页面自己身上,换个页面就忘了,而录音条不在那个页面里,够不着。它从不写进
// 录音配置。

import Combine
import Foundation

@MainActor
final class TranscriptReadingLayout: ObservableObject {
    static let shared = TranscriptReadingLayout()

    /// What the person picked, per topic. Absent until they pick.
    @Published private(set) var chosen: [String: NotebookTranscriptPresentationMode] = [:]
    /// What a topic's transcript opens in when nobody picked, as its page
    /// worked out from the recordings it holds. The recording bar ticks this
    /// one in ⋯ until a choice is made.
    @Published private(set) var defaults: [String: NotebookTranscriptPresentationMode] = [:]

    init() {}

    /// The layout in effect for a topic: the choice, else what its page
    /// opened in. Side by side is what a recording with languages opens in,
    /// so it stands in until the page has said.
    func mode(for notebookId: String?) -> NotebookTranscriptPresentationMode {
        guard let notebookId else { return .bilingualColumns }
        return chosen[notebookId] ?? defaults[notebookId] ?? .bilingualColumns
    }

    func choose(_ mode: NotebookTranscriptPresentationMode, for notebookId: String) {
        guard notebookId.isEmpty == false, chosen[notebookId] != mode else { return }
        chosen[notebookId] = mode
    }

    /// The transcript page reports the layout it would use on its own.
    func noteDefault(_ mode: NotebookTranscriptPresentationMode, for notebookId: String) {
        guard notebookId.isEmpty == false, defaults[notebookId] != mode else { return }
        defaults[notebookId] = mode
    }
}
