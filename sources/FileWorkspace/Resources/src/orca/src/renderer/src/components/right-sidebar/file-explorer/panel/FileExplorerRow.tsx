import React from 'react'
import {ChevronRight,CircleAlert,CircleSlash,Link,Loader2} from 'lucide-react'
import {cn} from '@/lib/class-names'
import {FileTypeIcon,FolderIcon} from '@/components/FileTypeIcon'
import {useTranslate} from '@/i18n/use-translate'
const STATUS_LABELS:Record<string,string>={modified:'M',added:'A',deleted:'D',renamed:'R',untracked:'?'};
// Native Explorer owns selection, menus, drag/drop and directory authority.
export function FileExplorerRow({node,isExpanded,isLoading=false,loadError=null,isSelected=false,nodeStatus=null,statusColor=null,isIgnored=false}:any){
const t=useTranslate();const showLoadError=node.isDirectory&&isExpanded&&!isLoading&&loadError!==null;
return <button className="tree-row flex w-full items-center gap-1 rounded-sm px-2 py-1 text-left text-xs transition-colors hover:bg-accent hover:text-foreground" style={{paddingLeft:`${node.depth*16+8}px`}}>
          {node.isDirectory ? (
            <>
              <ChevronRight
                className={cn(
                  'size-3 shrink-0 text-muted-foreground transition-transform',
                  isExpanded && 'rotate-90'
                )}
              />
              {isLoading ? (
                <Loader2 className="size-3 shrink-0 animate-spin text-muted-foreground" />
              ) : showLoadError ? (
                <CircleAlert className="size-3 shrink-0 text-destructive" />
              ) : (
                <FolderIcon
                  folderPath={node.name}
                  open={isExpanded}
                  className="size-3 shrink-0 text-muted-foreground"
                />
              )}
            </>
          ) : (
            <>
              <span className="size-3 shrink-0" />
              {node.isSymlink ? (
                <Link className="size-3 shrink-0 text-muted-foreground" />
              ) : (
                React.createElement(FileTypeIcon, {
                  filePath: node.relativePath || node.name,
                  className: 'size-3 shrink-0 text-muted-foreground'
                })
              )}
            </>
          )}
          <span
            className={cn(
              'truncate',
              isSelected && !nodeStatus && !isIgnored && 'text-accent-foreground',
              // Reserve space for italic overhang so truncation does not clip the final letter.
              isIgnored && 'italic pr-0.5'
            )}
            style={
              nodeStatus
                ? { color: statusColor ?? undefined }
                : isIgnored
                  ? { color: 'var(--git-decoration-ignored)' }
                  : undefined
            }
          >
            {node.name}
          </span>
          {showLoadError ? (
            <span className="w-0 flex-1 truncate text-destructive" title={loadError}>
              {loadError}
            </span>
          ) : null}
          {nodeStatus ? (
            <span
              className="ml-auto shrink-0 text-[10px] font-semibold tracking-wide mr-2"
              style={{ color: statusColor ?? undefined }}
            >
              {STATUS_LABELS[nodeStatus]}
            </span>
          ) : isIgnored ? (
            <CircleSlash
              aria-label={t(
                'auto.components.right.sidebar.FileExplorerRow.e26010014a',
                'Ignored by .gitignore'
              )}
              className="ml-auto size-3 shrink-0 mr-2"
              style={{ color: 'var(--git-decoration-ignored)' }}
            />
          ) : null}

</button>
}
