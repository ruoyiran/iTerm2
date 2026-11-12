import AppKit
import WebKit
import XCTest
import Darwin
@testable import iTerm2SharedARC
final class FileUIWebViewTests: XCTestCase, FileUIWebViewDelegate {
 private var done:XCTestExpectation?
 private var renderer:iTermFileWorkspaceWebView?
 private var editSession:FileUIEditSession?
 private var snapshot:iTermFileDocumentSnapshot?
 private var edits=0
 private let initialText=String(repeating:"a",count:300000)+"😀\r\n"
 private let pastedText="X\nY\rZ"+String(repeating:"😀",count:100000)


 func testNativePreviewReaderRejectsSpecialFilesLinksAndOversize() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  let regular=dir.appendingPathComponent("image.dat"),link=dir.appendingPathComponent("link"),fifo=dir.appendingPathComponent("fifo")
  let data=Data([0,1,2,3]);try data.write(to:regular)
  XCTAssertEqual(try iTermFilePreviewViewController.read(path:regular.path),data)
  try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:regular.path)
  XCTAssertThrowsError(try iTermFilePreviewViewController.read(path:link.path))
  XCTAssertEqual(mkfifo(fifo.path,0o600),0)
  XCTAssertThrowsError(try iTermFilePreviewViewController.read(path:fifo.path))
  let file=try FileHandle(forWritingTo:regular);try file.truncate(atOffset:10*1024*1024+1);try file.close()
  XCTAssertThrowsError(try iTermFilePreviewViewController.read(path:regular.path))
 }
 func testReusedNativeControllerEditsTheReplacementDocument() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  let first=dir.appendingPathComponent("first.txt"),second=dir.appendingPathComponent("second.txt")
  try Data("first".utf8).write(to:first);try Data("second".utf8).write(to:second)
  let store=iTermFileDocumentStore(storageDirectory:dir.appendingPathComponent("drafts"))
  let resource=ProcessInfo.processInfo.environment["FILE_UI_RESOURCE_DIR"].map { URL(fileURLWithPath:$0) } ?? Bundle.main.resourceURL!.appendingPathComponent("FileWorkspaceUI")
  let runtime=iTermFileWorkspaceUIRuntime(documentStore:store,resourceDirectory:resource)
  let controller=iTermFileViewController(runtime:runtime,viewIdentifier:"reused-view")
  let observer=FileUIViewObserver();controller.delegate=observer
  defer {controller.shutdown();runtime.shutdown()}
  func open(_ path:URL)->iTermFileDocumentSnapshot? {
   let done=expectation(description:"open document");var result:iTermFileDocumentSnapshot?
   store.openFile(atPath:path.path){value,error in XCTAssertNil(error);result=value;done.fulfill()};wait(for:[done],timeout:5);return result
  }
  let firstSnapshot=try XCTUnwrap(open(first)),secondSnapshot=try XCTUnwrap(open(second))
  controller.applyContext(iTermFileBrowserContext(rootDirectory:dir.path,projectIdentifier:"p",worktreeIdentifier:"w",generation:1))
  controller.applyDocumentChanges(firstSnapshot,edits:nil);controller.view.frame=NSRect(x:0,y:0,width:480,height:600)
  let ready=expectation(description:"controller ready");observer.changed={status in if status.isReady {observer.changed=nil;ready.fulfill()}}
  controller.setVisible(true);controller.focusEditor();wait(for:[ready],timeout:20)
  func pasteAndFlush(_ text:String) throws {
   let web=try XCTUnwrap(controller.view.subviews.compactMap{$0 as? iTermFileWorkspaceWebView}.first)
   let accepted=expectation(description:"accepted edit")
   observer.changed={status in
    if status.error != nil {XCTFail("Native editor failure");observer.changed=nil;accepted.fulfill()}
    else if status.isDirty && !status.hasPendingEdits {observer.changed=nil;accepted.fulfill()}
   }
   web.send("paste",payload:["text":text]);wait(for:[accepted],timeout:10)
   let barrier=expectation(description:"barrier");controller.flushEdits(reason:.save){error in XCTAssertNil(error);barrier.fulfill()};wait(for:[barrier],timeout:7)
  }
  try pasteAndFlush("A")
  controller.applyDocumentChanges(secondSnapshot,edits:nil)
  try pasteAndFlush("B")
  let checked=expectation(description:"replacement text")
  store.snapshot(documentIdentifier:secondSnapshot.documentIdentifier){value in XCTAssertEqual(value?.text,"Bsecond");checked.fulfill()};wait(for:[checked],timeout:5)
  let flushed=expectation(description:"drafts");store.flushDrafts{_ in flushed.fulfill()};wait(for:[flushed],timeout:5)
 }
 func testWindowlessBundledEditorEditsRealDocumentAndFlushes() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  let path=dir.appendingPathComponent("test.txt");try Data(initialText.utf8).write(to:path)
  let store=iTermFileDocumentStore(storageDirectory:dir.appendingPathComponent("drafts"))
  let opened=expectation(description:"open");store.openFile(atPath:path.path){value,error in XCTAssertNil(error);self.snapshot=value;opened.fulfill()};wait(for:[opened],timeout:5)
  let snapshot=try XCTUnwrap(snapshot);editSession=FileUIEditSession(store:store,documentIdentifier:snapshot.documentIdentifier)
  let resource=ProcessInfo.processInfo.environment["FILE_UI_RESOURCE_DIR"].map { URL(fileURLWithPath:$0) } ?? Bundle.main.resourceURL!.appendingPathComponent("FileWorkspaceUI")
  let server=try iTermFileUIAssetServer(resourceDirectory:resource);defer { server.stop() }
  let started=expectation(description:"server");var url:URL?
  server.start {value in url=try? value.get();started.fulfill()};wait(for:[started],timeout:5)
  let renderer=iTermFileWorkspaceWebView(dataStore:.nonPersistent());self.renderer=renderer;renderer.frame=NSRect(x:0,y:0,width:480,height:600);renderer.fileDelegate=self
  defer {renderer.shutdown();self.renderer=nil;self.editSession=nil}
  done=expectation(description:"editor edit barrier")
  renderer.bind(viewIdentifier:"view",context:iTermFileBrowserContext(rootDirectory:dir.path,projectIdentifier:"p",worktreeIdentifier:"w",generation:1),token:"test-token",purpose:"editor")
  renderer.loadAssets(try XCTUnwrap(url));wait(for:[done!],timeout:30)
  XCTAssertEqual(edits,1)
  let checked=expectation(description:"check");store.snapshot(documentIdentifier:snapshot.documentIdentifier){value in XCTAssertEqual(value?.text,self.pastedText+self.initialText);checked.fulfill()};wait(for:[checked],timeout:5)
  let flushed=expectation(description:"drafts");store.flushDrafts{_ in flushed.fulfill()};wait(for:[flushed],timeout:5)
 }
 func fileUIWebViewReady(_ webView:iTermFileWorkspaceWebView) {
  webView.send("document",payload:["snapshot":snapshot!.fileUIDictionary(includeText:true)])
  webView.send("editAuthority",payload:["granted":true])
  webView.send("paste",payload:["text":pastedText])
 }
 func fileUIWebView(_ webView:iTermFileWorkspaceWebView,received type:String,payload:[String:Any],identifier:String) {
  if type=="edits" { edits += 1; editSession!.apply(payload){value,error in
   XCTAssertNil(error);webView.send("ack",payload:["sequence":payload["sequence"]!,"revision":String(value?.revision ?? 0)])
   webView.send("flush",payload:["suspend":true],identifier:"barrier")
  } }
  if type=="flushResult" {XCTAssertNil(payload["error"]);done?.fulfill();done=nil}
  if type=="error" {XCTFail("Editor reported synchronization error");done?.fulfill();done=nil}
 }
 func fileUIWebView(_ webView:iTermFileWorkspaceWebView,failed error:NSError) {XCTFail("Web renderer failure: \(error)");done?.fulfill();done=nil}
}

private final class FileUIViewObserver: NSObject, iTermFileViewControllerDelegate {
 var changed: ((iTermFileViewStatus) -> Void)?
 func fileViewDidReceiveFocus(_ controller: iTermFileViewController) {}
 func fileView(_ controller: iTermFileViewController, didChangeStatus status: iTermFileViewStatus) { changed?(status) }
 func fileView(_ controller: iTermFileViewController, didChangeViewState state: iTermFileViewState) {}
 func fileViewDidRequestPin(_ controller: iTermFileViewController) {}
 func fileView(_ controller: iTermFileViewController, didRequest command: iTermFileViewCommand) {}
}
