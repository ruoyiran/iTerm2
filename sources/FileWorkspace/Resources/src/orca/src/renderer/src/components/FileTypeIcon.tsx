import { createElement, type CSSProperties } from 'react'
import { Folder, FolderOpen } from 'lucide-react'
import {
  getFileTypeIcon,
  getPluginFileTypeIconIndex,
  getPluginFolderIconIndex
} from '@/lib/file-icons/file-type-icons'
type IconProps = { className?: string; style?: CSSProperties }

export function FileTypeIcon({filePath,className,style}:IconProps & {filePath:string}) {return createElement(getFileTypeIcon(filePath),{'aria-hidden':true,className,style})}
export function FolderIcon({open,className,style}:IconProps & {open:boolean,folderPath?:string}) {return createElement(open?FolderOpen:Folder,{'aria-hidden':true,className,style})}
