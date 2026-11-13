export class TreeState {
  constructor() { this.context(null); }
  context(value) {
    this.scope = value; this.pending = new Map(); this.directories = new Map(); this.expanded = new Set(); this.selected = new Set(); this.anchor = null; this.matches = new Map(); this.nameResults = null; this.searchIdentifier = null; this.error = null; this.truncated = false; this.skipped = 0; this.searching = false;
  }
  begin(identifier, path) { this.pending.set(identifier, path); }
  listing(token, identifier, path, entries, error) {
    if (token !== this.scope?.token || this.pending.get(identifier) !== path) return false;
    this.pending.delete(identifier);
    if(!error) {
      const children=new Set((entries??[]).filter(entry=>entry.isExpandable||entry.isDirectory).map(entry=>entry.path));
      const removed=(this.directories.get(path)?.entries??[]).filter(entry=>(entry.isExpandable||entry.isDirectory)&&!children.has(entry.path)).map(entry=>entry.path);
      const orphan=value=>removed.some(root=>value===root||value.startsWith(root+'/'));
      for(const directory of this.directories.keys())if(orphan(directory))this.directories.delete(directory);
      for(const [id,directory] of this.pending)if(orphan(directory))this.pending.delete(id);
      for(const directory of this.expanded)if(orphan(directory))this.expanded.delete(directory);
      for(const value of this.selected)if(orphan(value))this.selected.delete(value);
    }
    this.directories.set(path, {entries: entries ?? [], error}); return true;
  }
  toggle(path) { if (this.expanded.has(path)) this.expanded.delete(path); else this.expanded.add(path); }
  rows() {
    if (this.nameResults) return [...this.nameResults.values()].map(entry => ({...entry, depth: 0}));
    const result = []; const visit = (path, depth) => {
      for (const entry of this.directories.get(path)?.entries ?? []) {
        result.push({...entry, depth}); if (entry.isExpandable && this.expanded.has(entry.path)) visit(entry.path, depth + 1);
      }
    }; if (this.scope) visit(this.scope.rootDirectory, 0); return result;
  }
  select(path, mode) {
    if (mode === 'range' || mode === 'additive-range') {
      const paths = this.rows().map(row => row.path); const a = paths.indexOf(this.anchor), b = paths.indexOf(path);
      if (a >= 0 && b >= 0) { if (mode !== 'additive-range') this.selected.clear(); for (const value of paths.slice(Math.min(a,b),Math.max(a,b)+1)) this.selected.add(value); return; }
    }
    if (mode === 'toggle') { if (this.selected.has(path)) this.selected.delete(path); else this.selected.add(path); }
    else { this.selected.clear(); this.selected.add(path); }
    this.anchor = path;
  }
  startSearch(identifier, names = false) { this.searchIdentifier = identifier; this.matches.clear(); this.nameResults = names ? new Map() : null; this.error = null; this.truncated = false; this.skipped = 0; this.searching = true; }
  search(token, identifier, batch) {
    if (token !== this.scope?.token || identifier !== this.searchIdentifier) return false;
    if (this.nameResults) for (const entry of batch.entries ?? []) this.nameResults.set(entry.path, entry);
    for (const group of batch.matches ?? []) {
      const previous = this.matches.get(group.path);
      if (previous) previous.lines.push(...group.lines); else this.matches.set(group.path, {...group, lines:[...group.lines]});
    }
    this.error = batch.error ?? null; this.truncated ||= !!batch.isTruncated; this.skipped = batch.skippedFileCount ?? this.skipped; this.searching = !batch.isComplete; return true;
  }
  navigate(key, current) {
    const rows = this.rows(); if (!rows.length) return null;
    let i = Math.max(0, rows.findIndex(row => row.path === current)), row = rows[i];
    if (key === 'ArrowRight' && row.isExpandable) { if (!this.expanded.has(row.path)) return {toggle:row.path}; i = Math.min(rows.length - 1, i + 1); }
    else if (key === 'ArrowLeft') {
      if (this.expanded.has(row.path)) return {toggle:row.path};
      while (i > 0 && rows[--i].depth >= row.depth) {};
    } else if (key === 'ArrowDown') i++;
    else if (key === 'ArrowUp') i--;
    else if (key === 'Home') i=0;
    else if (key === 'End') i=rows.length-1;
    else if (key === 'PageDown') i+=10;
    else if (key === 'PageUp') i-=10;
    else return null;
    return {path:rows[Math.max(0,Math.min(rows.length-1,i))].path};
  }
}
export function snippetParts(snippet, ranges, column = 0) {
  const spans = ranges.map(r => [Math.max(0,r.location-column),Math.min(snippet.length,r.location+r.length-column)]).filter(([a,b])=>a<b).sort((a,b)=>a[0]-b[0]);
  const result=[];let cursor=0;
  for(const [start,end] of spans) { if(start>cursor) result.push({text:snippet.slice(cursor,start),match:false}); if(end>cursor) result.push({text:snippet.slice(Math.max(cursor,start),end),match:true}); cursor=Math.max(cursor,end); }
  if(cursor<snippet.length) result.push({text:snippet.slice(cursor),match:false}); return result;
}
