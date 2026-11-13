export class MessageBridge {
  constructor(post) { this.post = post; this.identity = null; }
  configure(identity) { this.identity = {...identity}; }
  send(type, payload = {}, requestIdentifier = crypto.randomUUID()) {
    if (!this.identity) return null;
    const message={protocolVersion:1,...this.identity,requestIdentifier,type,payload};
    const text=JSON.stringify(message);
    if(text.length<=131072)this.post(message);
    else {
      if(text.length>300*1024*1024)throw new Error('Message exceeds transport capacity');
      const parts=[];for(let start=0;start<text.length;){let end=Math.min(text.length,start+131072);if(end<text.length&&/[\uD800-\uDBFF]/.test(text[end-1]))end--;parts.push(text.slice(start,end));start=end;}
      const identifier=crypto.randomUUID();for(let index=0;index<parts.length;index++)this.post({...message,type:'chunkNative',payload:{identifier,index,total:parts.length,text:parts[index]}});
    }
    return requestIdentifier;
  }
  accept(message) {
    return message?.protocolVersion === 1 && !!this.identity && ['rendererEpoch','viewIdentifier','contextToken','generation'].every(key => message[key] === this.identity[key]);
  }
}
