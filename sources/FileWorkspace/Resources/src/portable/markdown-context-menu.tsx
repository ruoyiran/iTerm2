import { useState } from "react";
import {
  ContextMenu,
  ContextMenuTrigger,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSub,
  ContextMenuSubTrigger,
  ContextMenuSubContent,
  ContextMenuSeparator,
} from "../orca/src/renderer/src/components/ui/context-menu";
import { state, translate } from "./local-state";
// Orca's native editable-context-menu command groups, using the portable Radix surface.
const labels: Record<string, string> = {
  "add-link": "addLink",
  "inline-code": "inlineCode",
  "code-block": "codeBlock",
  blockquote: "quote",
  paragraph: "bodyText",
  "heading-1": "heading1",
  "heading-2": "heading2",
  "heading-3": "heading3",
  "heading-4": "heading4",
  "heading-5": "heading5",
  "bullet-list": "bulletList",
  "ordered-list": "numberedList",
  "task-list": "checklist",
  "insert-row-above": "insertRowAbove",
  "insert-row-below": "insertRowBelow",
  "delete-row": "deleteRow",
  "insert-column-left": "insertColumnLeft",
  "insert-column-right": "insertColumnRight",
  "delete-column": "deleteColumn",
  "delete-table": "deleteTable",
};
const groups = [
  [
    "Format",
    [
      ["Bold", "bold"],
      ["Italic", "italic"],
      ["Strikethrough", "strike"],
      ["Inline code", "inline-code"],
      ["Code block", "code-block"],
      ["Quote", "blockquote"],
    ],
  ],
  [
    "Paragraph",
    [
      ["Body text", "paragraph"],
      ["Heading 1", "heading-1"],
      ["Heading 2", "heading-2"],
      ["Heading 3", "heading-3"],
      ["Heading 4", "heading-4"],
      ["Heading 5", "heading-5"],
      ["Bullet list", "bullet-list"],
      ["Numbered list", "ordered-list"],
      ["Checklist", "task-list"],
    ],
  ],
  [
    "Insert",
    [
      ["Link", "add-link"],
      ["Image", "image"],
      ["Divider", "divider"],
      ["Code block", "code-block"],
    ],
  ],
] as const;
const tableCommands = [
  ["Insert row above", "insert-row-above"],
  ["Insert row below", "insert-row-below"],
  ["Delete row", "delete-row"],
  ["Insert column left", "insert-column-left"],
  ["Insert column right", "insert-column-right"],
  ["Delete column", "delete-column"],
  ["Delete table", "delete-table"],
] as const;
export function MarkdownContextMenu({
  children,
  writable,
  onCommand,
}: {
  children: React.ReactNode;
  writable: boolean;
  onCommand: (command: string) => void;
}) {
  const [target, setTarget] = useState<any>(null);
  const run = (command: string) =>
    state.dispatchMarkdownCommand?.({ ...target, command, tableTargetId: target?.targetId });
  const item = (label: string, command: string) => (
    <ContextMenuItem key={command} disabled={!writable} onSelect={() => run(command)}>
      {translate("auto.main.window.editableContextMenu." + (labels[command] ?? command), label)}
    </ContextMenuItem>
  );
  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>
        <div
          className="h-full"
          onContextMenu={(event) =>
            setTarget({ ...state.richMarkdownContextTarget, x: event.clientX, y: event.clientY })
          }
        >
          {children}
        </div>
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem onSelect={() => onCommand("copy")}>Copy</ContextMenuItem>
        <ContextMenuItem disabled={!writable} onSelect={() => onCommand("cut")}>
          Cut
        </ContextMenuItem>
        <ContextMenuItem disabled={!writable} onSelect={() => onCommand("paste")}>
          Paste
        </ContextMenuItem>
        <ContextMenuSeparator />
        {item("Add link", "add-link")}
        {groups.map(([label, commands]) => (
          <ContextMenuSub key={label}>
            <ContextMenuSubTrigger>
              {translate("auto.main.window.editableContextMenu." + label.toLowerCase(), label)}
            </ContextMenuSubTrigger>
            <ContextMenuSubContent>
              {commands.map(([name, command]) => item(name, command))}
            </ContextMenuSubContent>
          </ContextMenuSub>
        ))}
        {target?.targetId && (
          <ContextMenuSub>
            <ContextMenuSubTrigger>Table</ContextMenuSubTrigger>
            <ContextMenuSubContent>
              {tableCommands.map(([name, command]) => item(name, command))}
            </ContextMenuSubContent>
          </ContextMenuSub>
        )}
      </ContextMenuContent>
    </ContextMenu>
  );
}
