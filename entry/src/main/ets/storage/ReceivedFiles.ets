import { fileIo as fs, fileUri, picker, hash as fileHash } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { FileInfo, safeName } from '../model/Protocol';

export interface SelectedFile {
  uri: string;
  info: FileInfo;
}

export interface Receipt {
  id: string;
  name: string;
  size: number;
  sender: string;
  date: number;
}

export function selectFile(uri: string): SelectedFile {
  const source = fs.openSync(uri,fs.OpenMode.READ_ONLY);
  try {
    const stat = fs.statSync(source.fd);
    if (!stat.isFile()) throw new Error('请选择普通文件');
    const info: FileInfo = {id:util.generateRandomUUID(),fileName:safeName(new fileUri.FileUri(uri).name),
      size:stat.size,fileType:'application/octet-stream'};
    return {uri,info};
  } finally { fs.closeSync(source); }
}

export interface FileWriter {
  write(part: Uint8Array): void;
  finish(isCurrent: () => boolean, expectedHash?: string): Promise<void>;
  discard(): void;
}

export interface ReceiveStore {
  begin(info: FileInfo, sender: string): FileWriter;
}

export class ReceivedFiles implements ReceiveStore {
  private root: string;
  constructor(root: string) {
    this.root = root;
    if (!fs.accessSync(root)) fs.mkdirSync(root,true);
    for (const name of fs.listFileSync(this.root)) {
      if (name.startsWith('partial-')) fs.rmdirSync(this.root + '/' + name);
    }
  }

  begin(info: FileInfo, sender: string): IncomingFile { return new IncomingFile(this.root,info,sender); }

  history(): Receipt[] {
    const records: Receipt[] = [];
    for (const name of fs.listFileSync(this.root)) {
      if (name.startsWith('partial-')) continue;
      const record = JSON.parse(fs.readTextSync(this.root + '/' + name + '/record.json')) as Receipt;
      records.push(record);
    }
    return records.sort((a: Receipt,b: Receipt) => b.date - a.date);
  }

  async export(context: common.UIAbilityContext, record: Receipt): Promise<void> {
    const destinations = await new picker.DocumentViewPicker(context).save({newFileNames:[record.name]});
    if (!destinations.length) return;
    const dest = fs.openSync(destinations[0],fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const src = fs.openSync(this.root + '/' + record.id + '/data',fs.OpenMode.READ_ONLY);
      try { await fs.copyFile(src.fd,dest.fd); }
      finally { fs.closeSync(src); }
    } finally { fs.closeSync(dest); }
  }
}

export class IncomingFile implements FileWriter {
  private dir: string;
  private target: string;
  private handle: fs.File | undefined;
  private receipt: Receipt;
  written: number = 0;
  constructor(root: string, info: FileInfo, sender: string) {
    const id = util.generateRandomUUID();
    this.dir = root + '/partial-' + id;
    this.target = root + '/' + id;
    this.receipt = {id,name:safeName(info.fileName),size:info.size,sender,date:Date.now()};
    fs.mkdirSync(this.dir);
    try { this.handle = fs.openSync(this.dir + '/data',fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY); }
    catch (error) { fs.rmdirSync(this.dir); throw error as Error; }
  }

  write(part: Uint8Array): void {
    if (!this.handle || this.written + part.length > this.receipt.size) throw new Error('文件长度错误');
    let offset = 0;
    while (offset < part.length) {
      const n = fs.writeSync(this.handle.fd,part.buffer.slice(part.byteOffset+offset,part.byteOffset+part.length));
      if (n <= 0) throw new Error('文件写入失败');
      this.written += n;
      offset += n;
    }
  }

  async finish(isCurrent: () => boolean, expectedHash?: string): Promise<void> {
    if (!this.handle || this.written !== this.receipt.size) throw new Error('文件不完整');
    fs.closeSync(this.handle);
    this.handle = undefined;
    if (expectedHash) {
      const actual = await fileHash.hash(this.dir + '/data','sha256');
      if (actual.toUpperCase() !== expectedHash.toUpperCase()) throw new Error('SHA256');
    }
    if (!isCurrent()) throw new Error('接收已取消');
    const record = fs.openSync(this.dir + '/record.json',fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try { fs.writeSync(record.fd,JSON.stringify(this.receipt)); }
    finally { fs.closeSync(record); }
    fs.renameSync(this.dir,this.target);
  }

  discard(): void {
    if (this.handle) { fs.closeSync(this.handle); this.handle = undefined; }
    if (fs.accessSync(this.dir)) fs.rmdirSync(this.dir);
  }
}
