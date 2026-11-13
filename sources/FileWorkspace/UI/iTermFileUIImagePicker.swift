import AppKit
import UniformTypeIdentifiers

enum FileUIImagePicker {
    static func pick(window: NSWindow?, isCurrent: @escaping () -> Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        let selected: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { completion(.success(["cancelled": true])); return }
            guard isCurrent() else { completion(.failure(fileUIError(2))); return }
            let selected = url.resolvingSymlinksInPath().standardizedFileURL
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<[String: Any], Error> = Result {
                    let files = try FileContentService(rootDirectory: selected.deletingLastPathComponent().path)
                    let data = try files.readBytes(selected.path, maximum: 10 * 1024 * 1024)
                    guard let mime = UTType(filenameExtension: selected.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/") else { throw fileUIError(4) }
                    return ["dataURL": "data:" + mime + ";base64," + data.base64EncodedString(), "cancelled": false]
                }
                DispatchQueue.main.async { completion(isCurrent() ? result : .failure(fileUIError(2))) }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: selected) }
        else { panel.begin(completionHandler: selected) }
    }
}
