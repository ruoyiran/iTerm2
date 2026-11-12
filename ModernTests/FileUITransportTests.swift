import Foundation
import XCTest
import CryptoKit
import Network
@testable import iTerm2SharedARC
final class FileUITransportTests: XCTestCase {
 func testFenceRequiresExactIdentityAndUInt64String() {
  let fence = FileUIMessageFence(epoch: "e", view: "v", token: "t", generation: UInt64.max)
  let valid: [String: Any] = ["protocolVersion": 1, "rendererEpoch": "e", "viewIdentifier": "v", "contextToken": "t", "generation": String(UInt64.max), "type": "focus", "requestIdentifier": "r", "payload": [:]]
  XCTAssertTrue(fence.accepts(valid))
  for key in ["rendererEpoch", "viewIdentifier", "contextToken", "generation"] {
   var changed=valid; changed[key]="old"; XCTAssertFalse(fence.accepts(changed))
  }
  var changed=valid;changed["protocolVersion"]=2;XCTAssertFalse(fence.accepts(changed))
  changed["protocolVersion"]=1.5;XCTAssertFalse(fence.accepts(changed))
 }
 func testLoopbackServesOnlyManifestResources() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:dir) }
  let body=Data("worker content".utf8)
  try body.write(to:dir.appendingPathComponent("worker.js"))
  let digest=SHA256.hash(data:body).map { String(format:"%02x",$0) }.joined()
  let manifest: [String:Any] = ["version":1,"files":[["path":"worker.js","bytes":body.count,"sha256":digest,"mime":"text/javascript; charset=utf-8"]]]
  try JSONSerialization.data(withJSONObject:manifest).write(to:dir.appendingPathComponent("manifest.json"))
  let server=try iTermFileUIAssetServer(resourceDirectory:dir);defer {server.stop()}
  let ready=expectation(description:"ready");var endpoint:URL?
  server.start { result in endpoint=try? result.get();ready.fulfill() }
  wait(for:[ready],timeout:5);XCTAssertNotNil(endpoint)
  guard let endpoint=endpoint else {return}
  XCTAssertEqual(endpoint.host,"127.0.0.1")
  func request(_ name:String,_ method:String="GET",host:String?=nil)->(Int,Data?) {
   let done=expectation(description:name+method);var code=0;var result:Data?
   var req=URLRequest(url:endpoint.deletingLastPathComponent().appendingPathComponent(name));req.httpMethod=method
   if let host=host { req.setValue(host,forHTTPHeaderField:"Host") }
   URLSession.shared.dataTask(with:req) { data,response,_ in code=(response as? HTTPURLResponse)?.statusCode ?? 0;result=data;done.fulfill() }.resume()
   wait(for:[done],timeout:5);return(code,result)
  }
  let response=request("worker.js");XCTAssertEqual(response.0,200);XCTAssertEqual(response.1,body)
  XCTAssertEqual(request("user-file.txt").0,404)
  XCTAssertEqual(request("worker.js","POST").0,405)
  XCTAssertEqual(request("worker.js","GET",host:"evil.invalid").0,403)
  XCTAssertEqual(request("worker.js","HEAD").1?.count,0)
  func rawRequest(_ request:String)->String {
   let done=expectation(description:"raw request");var bytes=Data()
   let connection=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(endpoint.port!))!,using:.tcp)
   let queue=DispatchQueue(label:"file-ui-test-client")
   func receive() {
    connection.receive(minimumIncompleteLength:1,maximumLength:32768){data,_,complete,error in
     if let data=data {bytes.append(data)}
     if complete || error != nil {connection.cancel();done.fulfill()}else{receive()}
    }
   }
   connection.stateUpdateHandler={state in if case .ready=state {connection.send(content:Data(request.utf8),completion:.contentProcessed{_ in receive()})}}
   connection.start(queue:queue);wait(for:[done],timeout:5);return String(data:bytes,encoding:.utf8) ?? ""
  }
  let host="Host: 127.0.0.1:\(endpoint.port!)\r\n"
  XCTAssertTrue(rawRequest("GET  HTTP/1.1\r\n"+host+"\r\n").hasPrefix("HTTP/1.1 400"))
  XCTAssertTrue(rawRequest("GET /bad/../worker.js HTTP/1.1\r\n"+host+"\r\n").hasPrefix("HTTP/1.1 404"))
  XCTAssertTrue(rawRequest("GET \(endpoint.path) HTTP/1.1\r\n"+host+"Transfer-Encoding: chunked\r\n\r\n").hasPrefix("HTTP/1.1 400"))
  XCTAssertTrue(rawRequest("GET \(endpoint.path) HTTP/1.1\r\n"+host+"X-Fill: "+String(repeating:"a",count:8200)+"\r\n\r\n").hasPrefix("HTTP/1.1 431"))

 }
 func testNativeEditSessionAppliesRealStoreTransactionsAndRejectsReplay() throws {
  let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:dir)}
  let path=dir.appendingPathComponent("test.txt");try Data("a😀\r\nb".utf8).write(to:path)
  let store=iTermFileDocumentStore(storageDirectory:dir.appendingPathComponent("drafts"))
  var snapshot:iTermFileDocumentSnapshot?;let opened=expectation(description:"opened")
  store.openFile(atPath:path.path){value,_ in snapshot=value;opened.fulfill()};wait(for:[opened],timeout:5)
  let original=try XCTUnwrap(snapshot)
  let session=FileUIEditSession(store:store,documentIdentifier:original.documentIdentifier)
  let payload:[String:Any] = ["documentIdentifier":original.documentIdentifier,"sequence":"1","expectedRevision":String(original.revision),"edits":[["location":5,"length":1,"replacement":"B"]]]
  let applied=expectation(description:"applied")
  session.apply(payload){value,error in XCTAssertNil(error);XCTAssertEqual(value?.text,"a😀\r\nB");applied.fulfill()};wait(for:[applied],timeout:5)
  let replay=expectation(description:"replay")
  session.apply(payload){_,error in XCTAssertNotNil(error);replay.fulfill()};wait(for:[replay],timeout:5)
  let flushed=expectation(description:"flush");store.flushDrafts{_ in flushed.fulfill()};wait(for:[flushed],timeout:5)
 }
 func testBrowserIntentRejectsEscapedPathsAndConvertsPlacement() {
  let context=iTermFileBrowserContext(rootDirectory:"/root",projectIdentifier:"p",worktreeIdentifier:"w",generation:4)
  XCTAssertNil(iTermFileBrowserRequest(identifier:"r",context:context,type:"trash",payload:["paths":["/root/../outside"]]))
  let request=iTermFileBrowserRequest(identifier:"r",context:context,type:"openFile",payload:["path":"/root/a","placement":"verticalSplit","activation":"pinned","lineNumber":2,"utf16Column":3])
  XCTAssertEqual(request?.openRequest?.placement,.verticalSplit)
  XCTAssertEqual(request?.openRequest?.lineNumber,2)
  XCTAssertNil(iTermFileBrowserRequest(identifier:"r",context:context,type:"openTerminal",payload:["directoryPath":"/root","placement":"floatingPane"]))
 }

 func testChunkingPreservesUnicodeAndAssemblerRejectsOutOfOrder() throws {
  let text=String(repeating:"a",count:131071)+"😀"+String(repeating:"b",count:300000)
  let chunks=fileUIChunks(text)
  XCTAssertGreaterThan(chunks.count,1);XCTAssertEqual(chunks.joined(),text)
  let assembler=FileUIChunkAssembler()
  XCTAssertNil(assembler.accept(["identifier":"x","index":1,"total":2,"text":"x"]))
  XCTAssertNil(assembler.accept(["identifier":"x","index":0,"total":2,"text":"{\"x\":" ]))
  let message=assembler.accept(["identifier":"x","index":1,"total":2,"text":"1}"])
  XCTAssertEqual(message?["x"] as? Int,1)
 }

}
