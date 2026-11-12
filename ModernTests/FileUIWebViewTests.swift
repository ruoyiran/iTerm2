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




 private func withEditor(_ body: (iTermFileViewController, iTermFileDocumentStore, iTermFileDocumentSnapshot, iTermFileWorkspaceUIRuntime, iTermFileWorkspaceWebView) throws -> Void) throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  let path=dir.appendingPathComponent("barrier.txt");try Data("base".utf8).write(to:path)
  let store=iTermFileDocumentStore(storageDirectory:dir.appendingPathComponent("drafts"))
  let opened=expectation(description:"open fixture");var snapshot:iTermFileDocumentSnapshot?
  store.openFile(atPath:path.path){value,error in XCTAssertNil(error);snapshot=value;opened.fulfill()};wait(for:[opened],timeout:5)
  let resource=ProcessInfo.processInfo.environment["FILE_UI_RESOURCE_DIR"].map { URL(fileURLWithPath:$0) } ?? Bundle.main.resourceURL!.appendingPathComponent("FileWorkspaceUI")
  let runtime=iTermFileWorkspaceUIRuntime(documentStore:store,resourceDirectory:resource,makeRenderer:{dataStore in
   let web=iTermFileWorkspaceWebView(dataStore:dataStore)
   web.configuration.userContentController.addUserScript(WKUserScript(source:"globalThis.MonacoEnvironment = { globalAPI: true };",injectionTime:.atDocumentStart,forMainFrameOnly:true))
   return web
  })
  let controller=iTermFileViewController(runtime:runtime,viewIdentifier:UUID().uuidString), observer=FileUIViewObserver()
  defer {
   observer.changed=nil;controller.shutdown();runtime.shutdown()
   let flushed=expectation(description:"fixture drafts");store.flushDrafts{_ in flushed.fulfill()};wait(for:[flushed],timeout:5)
  }
  controller.delegate=observer;controller.applyContext(iTermFileBrowserContext(rootDirectory:dir.path,projectIdentifier:"p",worktreeIdentifier:"w",generation:1));controller.applyDocumentChanges(try XCTUnwrap(snapshot),edits:nil)
  controller.view.frame=NSRect(x:0,y:0,width:480,height:600)
  let ready=expectation(description:"fixture ready");observer.changed={status in if status.isReady {observer.changed=nil;ready.fulfill()}}
  controller.setVisible(true);controller.focusEditor();wait(for:[ready],timeout:20)
  let web=try XCTUnwrap(controller.view.subviews.compactMap{$0 as? iTermFileWorkspaceWebView}.first)
  flush(controller,.save)
  try body(controller,store,try XCTUnwrap(snapshot),runtime,web)
 }
 private func flush(_ controller:iTermFileViewController,_ reason:iTermFileFlushReason) {
  let done=expectation(description:"flush fixture");controller.flushEdits(reason:reason){error in XCTAssertNil(error);done.fulfill()};wait(for:[done],timeout:7)
 }
 private func evaluate(_ web:WKWebView,_ expression:String)->Any? {
  let done=expectation(description:"evaluate bundled UI");var value:Any?
  web.callAsyncJavaScript(expression,arguments:[:],in:nil,in:.page){result in
   switch result {case .success(let result):value=result;case .failure(let error):XCTFail("Evaluation failed: \(error)")};done.fulfill()
  };wait(for:[done],timeout:7);return value
 }
 func testControllerCloseAndSuspendSurviveFocusUntilExplicitResume() throws {
  try withEditor {controller,store,snapshot,_,web in
   for reason in [iTermFileFlushReason.close,.suspend] {
    flush(controller,reason);controller.focusEditor()
    XCTAssertFalse(controller.canPerform(.paste));web.send("paste",payload:["text":"blocked"]);flush(controller,.save)
    let unchanged=expectation(description:"barrier retained")
    store.snapshot(documentIdentifier:snapshot.documentIdentifier){value in XCTAssertEqual(value?.text,"base");unchanged.fulfill()};wait(for:[unchanged],timeout:5)
    controller.resumeEditing();controller.focusEditor();XCTAssertTrue(controller.canPerform(.paste))
   }
   web.send("paste",payload:["text":"accepted"]);flush(controller,.save)
   let accepted=expectation(description:"resume permits edit")
   store.snapshot(documentIdentifier:snapshot.documentIdentifier){value in XCTAssertEqual(value?.text,"acceptedbase");accepted.fulfill()};wait(for:[accepted],timeout:5)
  }
 }
 func testDocumentNotificationsCannotReopenSuspendedOrFailedMonaco() throws {
  try withEditor {controller,store,snapshot,_,web in
   let readOnly="return monaco.editor.getEditors()[0].getOption(monaco.editor.EditorOption.readOnly)"
   XCTAssertEqual(evaluate(web,readOnly) as? Bool,false)
   flush(controller,.close);XCTAssertEqual(evaluate(web,readOnly) as? Bool,true)
   controller.applyDocumentChanges(snapshot,edits:nil)
   XCTAssertEqual(evaluate(web,readOnly) as? Bool,true)
   let changed=expectation(description:"later document revision")
   var later:iTermFileDocumentSnapshot?
   store.applyEdits([iTermFileTextEdit(range:NSRange(location:0,length:1),replacement:"B")],documentIdentifier:snapshot.documentIdentifier,expectedRevision:snapshot.revision){value,error in XCTAssertNil(error);later=value;changed.fulfill()};wait(for:[changed],timeout:5)
   XCTAssertEqual(evaluate(web,readOnly) as? Bool,true)
   controller.resumeEditing();controller.focusEditor();XCTAssertEqual(evaluate(web,readOnly) as? Bool,false)
   web.send("ack",payload:["sequence":"999","revision":"999"])
   XCTAssertEqual(evaluate(web,readOnly) as? Bool,true)
   controller.applyDocumentChanges(try XCTUnwrap(later),edits:nil)
   XCTAssertEqual(evaluate(web,readOnly) as? Bool,true)
   web.send("editAuthority",payload:["granted":true]);web.send("resume")
   XCTAssertEqual(evaluate(web,readOnly) as? Bool,true)
  }
 }


 func testCompletedAuthorityTransferCanReturnToPreviousPane() throws {
  try withEditor {first,store,snapshot,runtime,firstWeb in
   let second=iTermFileViewController(runtime:runtime,viewIdentifier:UUID().uuidString), observer=FileUIViewObserver()
   defer {observer.changed=nil;second.shutdown()}
   second.delegate=observer;second.applyContext(iTermFileBrowserContext(rootDirectory:(snapshot.filePath as NSString).deletingLastPathComponent,projectIdentifier:"p",worktreeIdentifier:"w",generation:1));second.applyDocumentChanges(snapshot,edits:nil)
   let ready=expectation(description:"second pane ready");observer.changed={status in if status.isReady {observer.changed=nil;ready.fulfill()}}
   second.setVisible(true);wait(for:[ready],timeout:20)
   let secondWeb=try XCTUnwrap(second.view.subviews.compactMap{$0 as? iTermFileWorkspaceWebView}.first)
   let writable="return new Promise(resolve => { const editor = monaco.editor.getEditors()[0], key = monaco.editor.EditorOption.readOnly; if (!editor.getOption(key)) { resolve(true); return; } const subscription = editor.onDidChangeConfiguration(() => { if (!editor.getOption(key)) { subscription.dispose(); resolve(true); } }); })"
   second.focusEditor();XCTAssertEqual(evaluate(secondWeb,writable) as? Bool,true)
   XCTAssertEqual(evaluate(firstWeb,"return monaco.editor.getEditors()[0].getOption(monaco.editor.EditorOption.readOnly)") as? Bool,true)
   secondWeb.send("paste",payload:["text":"b"]);flush(second,.save)
   first.focusEditor();XCTAssertEqual(evaluate(firstWeb,writable) as? Bool,true)
   XCTAssertEqual(evaluate(secondWeb,"return monaco.editor.getEditors()[0].getOption(monaco.editor.EditorOption.readOnly)") as? Bool,true)
   firstWeb.send("paste",payload:["text":"a"]);flush(first,.save)
   let checked=expectation(description:"both edits kept")
   store.snapshot(documentIdentifier:snapshot.documentIdentifier){value in XCTAssertEqual(value?.text,"abbase");checked.fulfill()};wait(for:[checked],timeout:5)
  }
 }
 func testBrowserQueryFocusSurvivesInitialReadinessAndContextReconfiguration() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:dir)}
  let store=iTermFileDocumentStore(storageDirectory:dir)
  let resource=ProcessInfo.processInfo.environment["FILE_UI_RESOURCE_DIR"].map { URL(fileURLWithPath:$0) } ?? Bundle.main.resourceURL!.appendingPathComponent("FileWorkspaceUI")
  let runtime=iTermFileWorkspaceUIRuntime(documentStore:store,resourceDirectory:resource),controller=iTermFileBrowserViewController(runtime:runtime),observer=FileUIBrowserObserver()
  defer {observer.listed=nil;controller.shutdown();runtime.shutdown()}
  controller.delegate=observer;controller.view.frame=NSRect(x:0,y:0,width:320,height:600)
  controller.applyContext(iTermFileBrowserContext(rootDirectory:"/r",projectIdentifier:"p",worktreeIdentifier:"w",generation:1),title:"Root")
  controller.focusQuery(contents:true)
  let first=expectation(description:"first surface");observer.listed={observer.listed=nil;first.fulfill()};controller.setVisible(true);wait(for:[first],timeout:20)
  let web=try XCTUnwrap(controller.view.subviews.compactMap{$0 as? iTermFileWorkspaceWebView}.first)
  XCTAssertEqual(evaluate(web,"return document.activeElement.dataset.query") as? String,"contents")
  let second=expectation(description:"replacement surface");observer.listed={observer.listed=nil;second.fulfill()}
  controller.applyContext(iTermFileBrowserContext(rootDirectory:"/r/sub",projectIdentifier:"p",worktreeIdentifier:"w",generation:2),title:"Subtree")
  controller.focusQuery(contents:false);wait(for:[second],timeout:20)
  XCTAssertEqual(evaluate(web,"return document.activeElement.dataset.query") as? String,"names")
 }
 func testAbandonedControllersDoNotRetainRendererLeasesOrLoadAssets() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:dir)}
  let path=dir.appendingPathComponent("file.txt");try Data("text".utf8).write(to:path)
  let store=iTermFileDocumentStore(storageDirectory:dir.appendingPathComponent("drafts"));let opened=expectation(description:"file");var snapshot:iTermFileDocumentSnapshot?
  store.openFile(atPath:path.path){value,_ in snapshot=value;opened.fulfill()};wait(for:[opened],timeout:5)
  let resource=ProcessInfo.processInfo.environment["FILE_UI_RESOURCE_DIR"].map { URL(fileURLWithPath:$0) } ?? Bundle.main.resourceURL!.appendingPathComponent("FileWorkspaceUI")
  var created=[WeakFileUIWebView]()
  let runtime=iTermFileWorkspaceUIRuntime(documentStore:store,resourceDirectory:resource,makeRenderer:{dataStore in let web=iTermFileWorkspaceWebView(dataStore:dataStore);created.append(WeakFileUIWebView(web));return web})
  defer {runtime.shutdown()}
  weak var abandonedBrowser:iTermFileBrowserViewController?
  weak var abandonedFile:iTermFileViewController?
  autoreleasepool {
   for _ in 0..<4 {
    let browser=iTermFileBrowserViewController(runtime:runtime);abandonedBrowser=browser;browser.setVisible(true)
    let file=iTermFileViewController(runtime:runtime,viewIdentifier:UUID().uuidString);abandonedFile=file;file.applyDocumentChanges(snapshot!,edits:nil);file.setVisible(true)
   }
  }
  XCTAssertNil(abandonedBrowser);XCTAssertNil(abandonedFile)
  let settled=expectation(description:"startup settled");var probe:iTermFileWorkspaceWebView?
  let probeOwner=NSObject()
  runtime.acquire(owner:probeOwner) {web,error in XCTAssertNil(error);probe=web;settled.fulfill()};withExtendedLifetime(probeOwner) {wait(for:[settled],timeout:20)}
  let owned=try XCTUnwrap(probe)
  for item in created where item.value !== owned {XCTAssertNil(item.value,"Abandoned acquisition retained a renderer")}
  runtime.release(owned)
  let cancellationOwner=NSObject()
  runtime.acquire(owner:cancellationOwner) {web,error in
   XCTAssertNil(error);XCTAssertTrue(web === owned)
   web?.bind(viewIdentifier:"cancelled",context:nil,token:"cancelled",purpose:"explorer")
   if let web=web {runtime.release(web)}
  }
  XCTAssertFalse(owned.isLoading);XCTAssertNil(owned.url)
 }
 func testOversizedTextUsesInformationViewInsteadOfEmptyEditor() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  let path=dir.appendingPathComponent("large.txt");try Data().write(to:path)
  let file=try FileHandle(forWritingTo:path);try file.truncate(atOffset:10*1024*1024+1);try file.close()
  let store=iTermFileDocumentStore(storageDirectory:dir.appendingPathComponent("drafts"))
  var snapshot:iTermFileDocumentSnapshot?;let opened=expectation(description:"oversize snapshot")
  store.openFile(atPath:path.path){value,error in XCTAssertNil(error);snapshot=value;opened.fulfill()};wait(for:[opened],timeout:5)
  let resource=ProcessInfo.processInfo.environment["FILE_UI_RESOURCE_DIR"].map { URL(fileURLWithPath:$0) } ?? Bundle.main.resourceURL!.appendingPathComponent("FileWorkspaceUI")
  let runtime=iTermFileWorkspaceUIRuntime(documentStore:store,resourceDirectory:resource)
  let controller=iTermFileViewController(runtime:runtime,viewIdentifier:"large")
  defer {controller.shutdown();runtime.shutdown()}
  controller.applyContext(iTermFileBrowserContext(rootDirectory:dir.path,projectIdentifier:"p",worktreeIdentifier:"w",generation:1))
  controller.applyDocumentChanges(try XCTUnwrap(snapshot),edits:nil)
  let observer=FileUIViewObserver();controller.delegate=observer;let ready=expectation(description:"information ready")
  observer.changed={status in if status.isReady {observer.changed=nil;ready.fulfill()}}
  controller.setVisible(true);wait(for:[ready],timeout:20)
  XCTAssertTrue(controller.status.isReadOnly)
  XCTAssertFalse(controller.canPerform(.find))
  XCTAssertFalse(controller.canPerform(.saveAs))
 }
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
  let quitBarrier=expectation(description:"quit barrier")
  runtime.flushAllEdits(reason:.quit){error in XCTAssertNil(error);quitBarrier.fulfill()};wait(for:[quitBarrier],timeout:7)
  XCTAssertFalse(controller.canPerform(.paste));controller.focusEditor();XCTAssertFalse(controller.canPerform(.paste))
  let web=try XCTUnwrap(controller.view.subviews.compactMap{$0 as? iTermFileWorkspaceWebView}.first)
  web.send("paste",payload:["text":"blocked"])
  let barrierCheck=expectation(description:"barrier remains closed")
  controller.flushEdits(reason:.save){error in XCTAssertNil(error);barrierCheck.fulfill()};wait(for:[barrierCheck],timeout:7)
  let unchanged=expectation(description:"no edit during quit")
  store.snapshot(documentIdentifier:firstSnapshot.documentIdentifier){value in XCTAssertEqual(value?.text,"Afirst");unchanged.fulfill()};wait(for:[unchanged],timeout:5)
  runtime.resumeEditing()
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

private final class FileUIBrowserObserver: NSObject, iTermFileBrowserViewControllerDelegate {
 var listed: (() -> Void)?
 func fileBrowser(_ controller: iTermFileBrowserViewController, didRequest request: iTermFileBrowserRequest) {
  if request.kind == .listDirectory { controller.applyListing([],directoryPath:request.directoryPath!,requestIdentifier:request.identifier,context:request.context,error:nil);listed?() }
 }
 func fileBrowserDidReceiveFocus(_ controller: iTermFileBrowserViewController) {}
}
private final class WeakFileUIWebView { weak var value:iTermFileWorkspaceWebView?; init(_ value:iTermFileWorkspaceWebView) {self.value=value} }
