export interface Endpoint {
  wait(writable: boolean): Promise<void>;
  close(): void;
}

export interface TlsStream extends Endpoint {
  address: string;
  handshake(): number;
  peerCertificate(): ArrayBuffer;
  read(): ArrayBuffer | number;
  write(data: ArrayBuffer, offset: number): number;
}

export interface Listener extends Endpoint {
  accept(): TlsStream | null;
}

export const wantRead: number;
export const wantWrite: number;
export function listen(certificate: string, privateKey: string, port: number): Listener;
