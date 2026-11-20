// Executes only in the private iTerm2 automation content world.
// Arguments are passed by WebKit, never interpolated into JavaScript source.
if (!globalThis.__itermAutomation || globalThis.__itermAutomation.document !== document) {
    const state = {
        document,
        token: typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : `${Date.now()}-${Math.random()}`,
        index: 0,
        generation: null,
        refs: new Map()
    };
    const fail = code => ({error_code: code});
    const connected = element => {
        if (!element || !element.isConnected) return false;
        try {
            let doc = element.ownerDocument;
            while (doc !== document) {
                const frame = doc.defaultView?.frameElement;
                if (!frame || !frame.isConnected || frame.contentDocument !== doc || doc.defaultView.location.origin !== location.origin) return false;
                doc = frame.ownerDocument;
            }
            return true;
        } catch (_) { return false; }
    };
    const visible = element => {
        if (!connected(element)) return false;
        const win = element.ownerDocument.defaultView;
        for (let p = element; p; p = p.parentElement || p.getRootNode()?.host) {
            const style = win.getComputedStyle(p);
            if (p.hidden || p.getAttribute('aria-hidden') === 'true' || style.display === 'none' || style.visibility === 'hidden') return false;
        }
        const frame = element.ownerDocument.defaultView?.frameElement;
        if (frame && !visible(frame)) return false;
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
    };
    const role = e => e.getAttribute('role') || ({
        BUTTON:'button', A:e.hasAttribute('href') ? 'link' : 'generic',
        INPUT: e.type === 'checkbox' ? 'checkbox' : e.type === 'radio' ? 'radio' : ['button','submit','reset'].includes(e.type) ? 'button' : 'textbox',
        TEXTAREA:'textbox', SELECT:'combobox', IMG:'img', H1:'heading', H2:'heading',
        H3:'heading', H4:'heading', H5:'heading', H6:'heading', P:'paragraph',
        LI:'listitem', UL:'list', OL:'list', TABLE:'table', TH:'columnheader', TD:'cell'
    }[e.tagName] || (e.isContentEditable ? 'textbox' : 'generic'));
    const text = value => String(value || '').replace(/\s+/g, ' ').trim().slice(0, 1000);
    const name = e => {
        const labelled = e.getAttribute('aria-labelledby');
        if (labelled) {
            const result = text(labelled.split(/\s+/).map(id => e.ownerDocument.getElementById(id)?.textContent || '').join(' '));
            if (result) return result;
        }
        return text(e.getAttribute('aria-label') || (e.labels ? Array.from(e.labels).map(l => l.textContent).join(' ') : '') || e.getAttribute('alt') || e.getAttribute('title') || (['INPUT','TEXTAREA','SELECT'].includes(e.tagName) ? (['button','submit','reset'].includes(e.type) ? e.value : e.getAttribute('placeholder')) : (e.innerText === undefined ? e.textContent : e.innerText)));
    };
    const resolve = args => {
        if (!state.generation || args.generation !== state.generation) return fail('stale_reference');
        const e = state.refs.get(args.ref);
        if (!connected(e)) return fail('element_not_found');
        return e;
    };
    const unsupported = e => (e.tagName === 'INPUT' && ['file','color','date','datetime-local','month','time','week'].includes(e.type)) || (e.tagName === 'A' && (e.hasAttribute('download') || (e.target && e.target !== '_self')));
    state.run = async (action, args, expectedOrigin, deadline) => {
        if (Date.now() >= deadline) return fail('timeout');
        if (location.origin !== expectedOrigin) return fail('navigation_changed');
        try {
            if (action === 'snapshot') {
                state.refs.clear();
                state.generation = `${state.token}:${++state.index}`;
                const nodes = [];
                let unsupportedFrames = 0;
                let truncated = false;
                const max = args.max_nodes || 1000;
                const walk = root => {
                    for (const e of root.children || []) {
                        if (!visible(e)) continue;
                        if (nodes.length >= max) { truncated = true; return; }
                        let r = role(e);
                        const accessibleName = name(e);
                        if (r === 'generic' && e.childElementCount === 0 && accessibleName && e.tagName !== 'IFRAME') r = 'text';
                        if (r !== 'generic') {
                            const ref = `e${state.refs.size + 1}`;
                            state.refs.set(ref,e);
                            const box = e.getBoundingClientRect();
                            const item = {ref,role:r,name:accessibleName,tag:e.tagName.toLowerCase(),disabled:!!e.disabled,frame:{x:box.x,y:box.y,width:box.width,height:box.height}};
                            if (e.tagName === 'INPUT') item.input_type = e.type;
                            if ('value' in e && e.type !== 'password' && e.type !== 'file') item.value = String(e.value).slice(0,1000);
                            if ('checked' in e) item.checked = e.checked;
                            nodes.push(item);
                        }
                        if (e.tagName === 'IFRAME' || e.tagName === 'FRAME') {
                            try {
                                const child = e.contentDocument;
                                if (!child || e.contentWindow.location.origin !== location.origin) { unsupportedFrames++; continue; }
                                walk(child.documentElement);
                            } catch (_) { unsupportedFrames++; }
                        } else {
                            if (e.shadowRoot) walk(e.shadowRoot);
                            walk(e);
                        }
                    }
                };
                walk(document.documentElement);
                return {generation:state.generation,url:location.href,title:document.title,nodes,unsupported_frames:unsupportedFrames,truncated};
            }
            if (args.generation && args.generation !== state.generation) return fail('stale_reference');
            if (action === 'wait') {
                if (args.state === 'ready') return {matched:document.readyState === 'complete',generation:state.generation};
                const e = document.querySelector(args.selector);
                const matched = ({attached:!!e,detached:!e,visible:visible(e),hidden:!visible(e)})[args.state];
                return {matched,generation:state.generation};
            }
            let element;
            if (args.ref) {
                element = resolve(args);
                if (element.error_code) return element;
                if (unsupported(element)) return fail('unsupported');
                if (!visible(element) || element.disabled || element.closest('[inert]')) return fail('element_not_interactable');
            }
            if (action === 'click') {
                if (!element || element.tagName === 'SELECT' || typeof element.click !== 'function') return fail('unsupported');
                element.scrollIntoView({block:'center',inline:'center'});
                element.click();
                return {generation:state.generation,clicked:true,trusted:false};
            }
            if (action === 'fill') {
                if (!element || element.readOnly) return fail('element_not_interactable');
                if (element.tagName === 'INPUT' && !['text','search','tel','url','email','password','number'].includes(element.type)) return fail('unsupported');
                if (element.isContentEditable) {
                    element.focus();
                    element.textContent = args.value;
                } else if (['INPUT','TEXTAREA','SELECT'].includes(element.tagName)) {
                    const prototype = Object.getPrototypeOf(element);
                    const setter = Object.getOwnPropertyDescriptor(prototype,'value')?.set;
                    if (!setter) return fail('unsupported');
                    element.focus();
                    setter.call(element,args.value);
                } else return fail('unsupported');
                const win = element.ownerDocument.defaultView;
                element.dispatchEvent(new win.Event('input',{bubbles:true,composed:true}));
                element.dispatchEvent(new win.Event('change',{bubbles:true}));
                if (!element.isContentEditable && element.value !== args.value) return fail('element_not_interactable');
                return {generation:state.generation,filled:true,trusted:false};
            }
            if (action === 'press_key') {
                const keys = ['Enter','Escape','Tab','Backspace','Delete','ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home','End',' '];
                if (!keys.includes(args.key) && Array.from(args.key).length !== 1) return fail('unsupported');
                element = element || document.activeElement;
                if (!element || !visible(element)) return fail('element_not_interactable');
                if (unsupported(element)) return fail('unsupported');
                element.focus();
                const win = element.ownerDocument.defaultView;
                element.dispatchEvent(new win.KeyboardEvent('keydown',{key:args.key,bubbles:true,composed:true}));
                element.dispatchEvent(new win.KeyboardEvent('keyup',{key:args.key,bubbles:true,composed:true}));
                return {generation:state.generation,dispatched:true,trusted:false,default_action:false};
            }
            if (action === 'scroll') {
                const target = element || window;
                target.scrollBy({left:args.x,top:args.y,behavior:'instant'});
                return {generation:state.generation,scrolled:true};
            }
            return fail('unsupported');
        } catch (error) {
            return fail(error.name === 'SyntaxError' ? 'invalid_request' : 'javascript_error');
        }
    };
    globalThis.__itermAutomation = state;
}
return await globalThis.__itermAutomation.run(action,args,expectedOrigin,deadline);
