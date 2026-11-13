import { memo, useMemo } from 'react'
import { formatToolDuration } from '../../../../../../shared/native-chat/tools/native-chat-tool-identity'
import { IpynbCellOutputs } from './IpynbCellOutputs'
import { IpynbRunPrompt } from '../cells/IpynbCellToolbar'
import { parseIpynbOutput, type IpynbCell, type IpynbOutput } from '../document/ipynb-parse'

export function IpynbCellRunOutputs({cell}:{cell:IpynbCell,filePath:string,cellKey:string}) { return <IpynbCellOutputs cell={cell} /> }
