import AppKit
import WebKit
import PDFKit
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




 private func descendants(_ view: NSView) -> [NSView] {
  [view] + view.subviews.flatMap { descendants($0) }
 }
 private func withPreview(_ name: String, data: Data, body: (iTermFileViewController) throws -> Void) throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  let path=dir.appendingPathComponent(name);try data.write(to:path)
  let store=iTermFileDocumentStore(storageDirectory:dir.appendingPathComponent("drafts"))
  let opened=expectation(description:"open preview fixture");var snapshot:iTermFileDocumentSnapshot?
  store.openFile(atPath:path.path){value,error in XCTAssertNil(error);snapshot=value;opened.fulfill()};wait(for:[opened],timeout:5)
  let resource=ProcessInfo.processInfo.environment["FILE_UI_RESOURCE_DIR"].map { URL(fileURLWithPath:$0) } ?? Bundle.main.resourceURL!.appendingPathComponent("FileWorkspaceUI")
  let runtime=iTermFileWorkspaceUIRuntime(documentStore:store,resourceDirectory:resource)
  let controller=iTermFileViewController(runtime:runtime,viewIdentifier:UUID().uuidString)
  defer {controller.shutdown();runtime.shutdown()}
  _ = NSApplication.shared
  let window=NSWindow(contentRect:NSRect(x:100,y:100,width:640,height:480),styleMask:[.titled,.closable],backing:.buffered,defer:false)
  window.isReleasedWhenClosed=false; window.title="iTerm2 File UI Test"; window.contentView=controller.view; window.orderFrontRegardless()
  defer {window.close()}
  controller.view.frame=NSRect(x:0,y:0,width:640,height:480)
  controller.applyDocumentChanges(try XCTUnwrap(snapshot),edits:nil);controller.setVisible(true)
  try body(controller)
 }
 private func waitForDOM(_ selector: String, in web: WKWebView) {
  _ = evaluate(web,"return new Promise(resolve => { const check = () => { if (document.querySelector(selector)) { observer.disconnect(); resolve(true); } }; const observer = new MutationObserver(check); observer.observe(document, { childList:true, subtree:true, attributes:true }); check(); });",arguments:["selector":selector])
 }
 private func previewWeb(_ controller: iTermFileViewController) throws -> iTermFileWorkspaceWebView {
  let ready=XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in controller.status.isReady},object:nil)
  wait(for:[ready],timeout:20)
  return try XCTUnwrap(descendants(controller.view).compactMap {$0 as? iTermFileWorkspaceWebView}.first)
 }
 func testImagePreviewZoomControlsChangeMagnification() throws {
  let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
  try withPreview("zoom.png",data:try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))) {controller in
   let web=try previewWeb(controller)
   waitForDOM("[data-orca-view] img",in:web)
   let result=evaluate(web,"const image = document.querySelector('[data-orca-view] img'); await image.decode(); const before=image.getBoundingClientRect().width; const zoom=document.querySelector('button[title*=\"zoom in\" i]'); zoom.click(); return new Promise(resolve => { const check=()=>{ const after=image.getBoundingClientRect().width; if(after>before){ observer.disconnect(); resolve({before,after}); } }; const observer=new MutationObserver(check); observer.observe(image,{attributes:true}); check(); }); ") as? [String:Any]
   XCTAssertGreaterThan((result?["after"] as? NSNumber)?.doubleValue ?? 0,(result?["before"] as? NSNumber)?.doubleValue ?? 0)
  }
 }
 func testPDFPreviewFindCommandsNavigateMatchesAcrossPages() throws {
  let data=NSMutableData(),consumer=try XCTUnwrap(CGDataConsumer(data:data))
  var box=CGRect(x:0,y:0,width:300,height:300)
  let context=try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&box,nil))
  for text in ["alpha first","unrelated","alpha last"] {
   context.beginPDFPage(nil);NSGraphicsContext.saveGraphicsState()
   NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
   (text as NSString).draw(at:NSPoint(x:20,y:200),withAttributes:[.font:NSFont.systemFont(ofSize:18)])
   NSGraphicsContext.restoreGraphicsState();context.endPDFPage()
  }
  context.closePDF()
  XCTAssertTrue(PDFDocument(data:data as Data)?.string?.contains("alpha") == true)
  try withPreview("find.pdf",data:data as Data) {controller in
   let web=try previewWeb(controller)
   waitForDOM("canvas",in:web)
   controller.perform(.find);waitForDOM("input",in:web)
   _=evaluate(web,"const input=document.querySelector('input'); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,'alpha'); input.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'alpha'}));")
   waitForDOM(".page[data-page-number='1'] .highlight.selected",in:web)
   controller.perform(.findNext)
   waitForDOM(".page[data-page-number='3'] .highlight.selected",in:web)
   controller.perform(.findPrevious)
   waitForDOM(".page[data-page-number='1'] .highlight.selected",in:web)
  }
 }
 func testMermaidPreviewRendersOriginalDiagramWithNativeResourcePolicy() throws {
  try withPreview("diagram.mmd",data:Data("graph TD\nA[Start] --> B[End]\n".utf8)) {controller in
   let web=try previewWeb(controller);waitForDOM("svg .node",in:web)
   let text=evaluate(web,"return new Promise(resolve=>{ const check=()=>{ const text=Array.from(document.querySelectorAll('svg .node')).map(node=>node.textContent).join(' '); if(text.includes('Start') && text.includes('End')){ observer.disconnect(); resolve(text); } }; const observer=new MutationObserver(check); observer.observe(document,{childList:true,subtree:true,characterData:true}); check(); });") as? String ?? ""
   XCTAssertTrue(text.contains("Start"));XCTAssertTrue(text.contains("End"))
  }
 }
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
 private func evaluate(_ web:WKWebView,_ expression:String,arguments:[String:Any]=[:])->Any? {
  let done=expectation(description:"evaluate bundled UI");var value:Any?;let scope=FileUIEvaluationScope()
  defer {scope.waiting=false}
  web.callAsyncJavaScript(expression+"; return null",arguments:arguments,in:nil,in:.page){result in
   guard scope.waiting else {return}
   switch result {case .success(let result):value=result;case .failure(let error):XCTFail("Evaluation failed [\(expression.prefix(120))]: \(error)")};done.fulfill()
  };wait(for:[done],timeout:7);return value
 }

 func testReadonlyTextSaveAsFlushesToNativeWhileBarriersStillDisableIt() throws {
  try withEditor {controller,store,snapshot,runtime,web in
   try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:snapshot.filePath)
   let changed=expectation(description:"readonly metadata")
   store.fileDidChange(atPath:snapshot.filePath){value,error in XCTAssertNil(error);XCTAssertTrue(value?.isReadOnly == true);changed.fulfill()};wait(for:[changed],timeout:5)
   XCTAssertTrue(controller.canPerform(.saveAs));XCTAssertFalse(controller.canPerform(.save))
   let observer=FileUIViewObserver();controller.delegate=observer;var requests=0
   let requested=expectation(description:"Save As after acknowledged flush")
   observer.requested={command in if command == .saveAs {requests += 1;requested.fulfill()}}
   controller.perform(.saveAs);wait(for:[requested],timeout:7)
   observer.requested={_ in requests += 1}
   flush(controller,.close);XCTAssertFalse(controller.canPerform(.saveAs));controller.perform(.saveAs);XCTAssertEqual(requests,1)
   controller.resumeEditing();XCTAssertTrue(controller.canPerform(.saveAs))
   let quit=expectation(description:"quit barrier");runtime.flushAllEdits(reason:.quit){error in XCTAssertNil(error);quit.fulfill()};wait(for:[quit],timeout:7)
   XCTAssertFalse(controller.canPerform(.saveAs));controller.perform(.saveAs);XCTAssertEqual(requests,1)
   runtime.resumeEditing();observer.requested=nil
  }
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
  let file=try FileHandle(forWritingTo:path);try file.truncate(atOffset:50*1024*1024+1);try file.close()
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
  if type=="hostRequest",payload["operation"] as? String=="settings" {webView.send("hostResult",payload:["result":FileUISettingsStore.defaults],identifier:identifier)}
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
 var requested: ((iTermFileViewCommand) -> Void)?
 var focused: (() -> Void)?
 func fileViewDidReceiveFocus(_ controller: iTermFileViewController) { focused?() }
 func fileView(_ controller: iTermFileViewController, didChangeStatus status: iTermFileViewStatus) { changed?(status) }
 func fileView(_ controller: iTermFileViewController, didChangeViewState state: iTermFileViewState) {}
 func fileViewDidRequestPin(_ controller: iTermFileViewController) {}
 func fileView(_ controller: iTermFileViewController, didRequest command: iTermFileViewCommand) { requested?(command) }
}

private final class FileUIBrowserObserver: NSObject, iTermFileBrowserViewControllerDelegate {
 var listed: (() -> Void)?
 func fileBrowser(_ controller: iTermFileBrowserViewController, didRequest request: iTermFileBrowserRequest) {
  if request.kind == .listDirectory { controller.applyListing([],directoryPath:request.directoryPath!,requestIdentifier:request.identifier,context:request.context,error:nil);listed?() }
 }
 func fileBrowserDidReceiveFocus(_ controller: iTermFileBrowserViewController) {}
}
private final class WeakFileUIWebView { weak var value:iTermFileWorkspaceWebView?; init(_ value:iTermFileWorkspaceWebView) {self.value=value} }

private final class PDFSearchObserver: NSObject, PDFDocumentDelegate {
 let downstream: PDFDocumentDelegate
 var emittedMatches=0
 init(downstream: PDFDocumentDelegate) { self.downstream=downstream }
 func didMatchString(_ instance: PDFSelection) { emittedMatches += 1;downstream.didMatchString?(instance) }
 func documentDidEndDocumentFind(_ notification: Notification) { downstream.documentDidEndDocumentFind?(notification) }
}

private final class FileUIEvaluationScope { var waiting = true }
