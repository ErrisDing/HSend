export const PORT = 53317;
export const GROUP = '224.0.0.167';
export const API = '/api/localsend/v2/';

export interface DeviceInfo {
  alias: string;
  version: string;
  fingerprint: string;
  deviceType: string;
  deviceModel?: string;
  port: number;
  protocol: string;
  announce?: boolean;
  download?: boolean;
}

export class Peer {
  address: string;
  info: DeviceInfo;
  constructor(address: string, info: DeviceInfo) {
    this.address = address;
    this.info = info;
  }
}

export interface FileInfo {
  id: string;
  fileName: string;
  size: number;
  fileType: string;
  sha256?: string;
}

export interface Offer {
  info: DeviceInfo;
  files: Record<string, FileInfo>;
}

export interface Ticket {
  sessionId: string;
  files: Record<string, string>;
}

export function hexFingerprint(bytes: Uint8Array): string {
  return Array.from(bytes).map((n: number) => n.toString(16).toUpperCase().padStart(2, '0')).join('');
}

export function layoutMode(width: number): number {
  if (width < 700) return 0;
  if (width < 800) return 1;
  return 2;
}

export function safeName(input: string): string {
  const parts = input.replace(/\\/g, '/').split('/');
  const name = parts[parts.length - 1].replace(/[\x00-\x1f]/g, '').trim();
  return name === '' || name === '.' || name === '..' ? 'file' : name;
}
