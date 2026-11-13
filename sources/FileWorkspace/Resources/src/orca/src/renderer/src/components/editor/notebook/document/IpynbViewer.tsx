import { isImeOwnedKeyboardEvent } from '@/lib/text-input/ime/ime-composition-keyboard-event'
import { useCallback, useMemo, useState } from 'react'
import { AlertCircle, Save } from 'lucide-react'
import { computeEditorFontSize } from '../../../../../../shared/editor/editor-font-zoom'
import { useAppStore } from '@/store/index'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog'
import { useShortcutKeyDetails } from '@/hooks/useShortcutLabel'
import { useTranslate } from '@/i18n/use-translate'
import { editorShortcutMatches } from '../../editor-shortcuts'
import { getShortcutPlatform } from '@/lib/keyboard/shortcut-platform'
import { IpynbCellToolbar, IpynbToolbarButton } from '../cells/IpynbCellToolbar'
import { IpynbCellSource } from '../cells/IpynbCellEditor'
import { IpynbCellRunOutputs, IpynbCellRunPrompt } from '../outputs/IpynbCellRun'
import { parseIpynb } from './ipynb-parse'
import { hasIpynbSourceDraft, useIpynbDocumentEditing } from './useIpynbDocumentEditing'
import { getIpynbCellKey } from './ipynb-source-drafts'
import { useIpynbScrollRestoration } from './useIpynbScrollRestoration'

type IpynbViewerProps = {
  content: string
  readOnly?: boolean
  fileId: string
  filePath: string
  worktreeId: string
  scrollCacheKey: string
  onContentChange: (content: string) => void
  onDirtyStateHint: (dirty: boolean) => void
  onSave: (content: string) => Promise<boolean>
}

export default function IpynbViewer({
  content,
  fileId,
  readOnly = false,
  filePath,
  worktreeId,
  scrollCacheKey,
  onContentChange,
  onDirtyStateHint,
  onSave
}: IpynbViewerProps): React.JSX.Element {
  const t = useTranslate()
  const editorFontZoomLevel = useAppStore((s) => s.editorFontZoomLevel)
  const [editingCellKey, setEditingCellKey] = useState<string | null>(null)
  const parsed = useMemo(() => {
    try {
      return { notebook: parseIpynb(content), error: null as string | null }
    } catch (error) {
      return {
        notebook: null,
        // Translated at render so the fallback follows the UI language without reparsing.
        error: error instanceof Error ? error.message : null
      }
    }
  }, [content])
  const deactivateEditor = useCallback((): void => setEditingCellKey(null), [])
  const {
    rootRef,
    setRootRef,
    flushOnFocusLeave,
    sourceDrafts,
    flushSourceDrafts,
    applyContent,
    updateCellSource,
    updateCellKind,
    insertCell,
    moveCell,
    deleteCell
  } = useIpynbDocumentEditing({
    content,
    fileId,
    notebook: parsed.notebook,
    onContentChange,
    onDirtyStateHint,
    onDeactivateEditor: deactivateEditor
  })
  useIpynbScrollRestoration(rootRef, scrollCacheKey, parsed.notebook !== null)
  const saveShortcut = useShortcutKeyDetails('editor.save')
  const fontSize = computeEditorFontSize(13, editorFontZoomLevel)

  const saveNotebook = useCallback(async (): Promise<void> => {
    const latestContent = flushSourceDrafts()
    await onSave(latestContent)
  }, [flushSourceDrafts, onSave])

  const handleNotebookKeyDownCapture = useCallback(
    (event: React.KeyboardEvent<HTMLDivElement>): void => {
      if (event.repeat || !editorShortcutMatches('editor.save', event)) {
        return
      }
      event.preventDefault()
      event.stopPropagation()
      void saveNotebook()
    },
    [saveNotebook]
  )

  // Shift+Enter runs a cell and moves to the next; Cmd/Ctrl+Enter runs it in place.
  if (parsed.error || !parsed.notebook) {
    return (
      <div className="flex h-full items-center justify-center bg-editor-surface p-6 text-sm text-muted-foreground">
        <div className="flex max-w-md items-start gap-3 rounded-md border border-border bg-background p-4">
          <AlertCircle className="mt-0.5 size-4 text-destructive" />
          <div>
            <div className="font-medium text-foreground">
              {t('auto.components.editor.IpynbViewer.c1601b23b2', 'Unable to render notebook')}
            </div>
            <div className="mt-1">
              {parsed.error ??
                t('auto.components.editor.IpynbViewer.invalidNotebook', 'Invalid notebook')}
            </div>
          </div>
        </div>
      </div>
    )
  }

  const { notebook } = parsed
  // Kernels are local Python only; other notebooks still render and edit.
  const canRun = false
  return (
    <div
      ref={setRootRef}
      className="h-full min-h-0 overflow-auto bg-editor-surface scrollbar-editor"
      style={{ fontSize }}
      onKeyDownCapture={handleNotebookKeyDownCapture}
      onBlur={flushOnFocusLeave}
    >
      <div className="sticky top-0 z-10 flex items-center gap-3 border-b border-border/60 bg-background/95 px-4 py-2 text-xs text-muted-foreground backdrop-blur">
        <span className="font-medium text-foreground">{filePath.split(/[/\\]/).pop()}</span>
        <span>
          {t('auto.components.editor.IpynbViewer.cellCount', '{{count}} cells', {
            count: notebook.cells.length,
            defaultValue_one: '{{count}} cell'
          })}
        </span>
        <span>{notebook.language}</span>
        <div className="ml-auto flex items-center gap-2">

          <IpynbToolbarButton
            disabled={readOnly}
            label={t('auto.components.editor.IpynbViewer.15ec40a735', 'Save notebook')}
            shortcut={saveShortcut}
            onClick={() => void saveNotebook()}
          >
            <Save className="size-3.5" />
          </IpynbToolbarButton>
        </div>
      </div>
      <div className="mx-auto flex max-w-[980px] flex-col gap-2 py-5 pr-5 pl-2">
        {notebook.cells.length === 0 ? (
          <div className="flex items-center justify-center rounded-md border border-border bg-background p-8 text-sm text-muted-foreground">
            {t('auto.components.editor.IpynbViewer.d6f37a640b', 'Empty notebook')}
          </div>
        ) : (
          notebook.cells.map((cell, index) => {
            const cellKey = getIpynbCellKey(cell, index)
            const source = hasIpynbSourceDraft(sourceDrafts, cellKey)
              ? (sourceDrafts[cellKey] ?? '')
              : cell.source
            return (
              <section
                key={cellKey}
                className="group relative flex gap-2 py-1.5"
              >
                {/* Mirrors the code surface's border and padding so the count shares the first line's box. */}
                <div className="flex w-12 shrink-0 justify-center border-y border-transparent py-1">
                  {cell.kind === 'code' ? (
                    <span>{cell.executionCount ?? " "}</span>
                  ) : null}
                </div>
                <div className="min-w-0 flex-1">
                  <IpynbCellSource
                    modelKey={
                      cell.id === null ? null : JSON.stringify([fileId, scrollCacheKey, cell.id])
                    }
                    cell={cell}
                    source={source}
                    active={!readOnly && editingCellKey === cellKey}
                    onActivate={() => {if(!readOnly)setEditingCellKey(cellKey)}}
                    onDeactivate={() =>
                      setEditingCellKey((current) => (current === cellKey ? null : current))
                    }
                    onChange={(nextSource) => updateCellSource(index, nextSource)}
                  />
                  <IpynbCellRunOutputs filePath={filePath} cellKey={cellKey} cell={cell} />
                </div>
                {!readOnly && <IpynbCellToolbar
                  kind={cell.kind}
                  canMoveUp={index > 0}
                  canMoveDown={index < notebook.cells.length - 1}
                  onKindChange={(kind) => updateCellKind(index, kind)}
                  onInsert={(offset, kind) => insertCell(index + offset, kind)}
                  onMove={(direction) => moveCell(index, direction)}
                  onDelete={() => deleteCell(index)}
                />}
              </section>
            )
          })
        )}
      </div>

    </div>
  )
}
