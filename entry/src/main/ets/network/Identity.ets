import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { cert } from '@kit.DeviceCertificateKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hexFingerprint } from '../model/Protocol';

export interface DeviceIdentity {
  certificate: string;
  key: string;
  fingerprint: string;
}

export function joinBytes(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((total: number, p: Uint8Array) => total + p.length, 0));
  let offset = 0;
  for (const p of parts) { out.set(p, offset); offset += p.length; }
  return out;
}

function der(tag: number, value: Uint8Array): Uint8Array {
  const size: number[] = [];
  let length = value.length;
  if (length < 128) size.push(length);
  else {
    while (length > 0) { size.unshift(length & 255); length = Math.floor(length / 256); }
    size.unshift(128 + size.length);
  }
  return joinBytes([new Uint8Array([tag]), new Uint8Array(size), value]);
}

function sequence(parts: Uint8Array[]): Uint8Array { return der(48, joinBytes(parts)); }
function ascii(text: string): Uint8Array { return new util.TextEncoder().encodeInto(text); }
export function pem(type: string, data: Uint8Array): string {
  const encoded = new util.Base64Helper().encodeToStringSync(data);
  const lines: string[] = [];
  for (let i = 0; i < encoded.length; i += 64) lines.push(encoded.slice(i, i + 64));
  return '-----BEGIN ' + type + '-----\n' + lines.join('\n') + '\n-----END ' + type + '-----\n';
}

export async function fingerprint(bytes: Uint8Array): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  await digest.update({data: bytes});
  return hexFingerprint((await digest.digest()).data);
}

export async function peerFingerprint(blob: cert.EncodingBlob): Promise<string> {
  const parsed = await cert.createX509Cert(blob);
  const encoded = await parsed.getEncoded();
  return fingerprint(encoded.data);
}

async function createIdentity(): Promise<DeviceIdentity> {
  const pair = await cryptoFramework.createAsyKeyGenerator('RSA2048').generateKeyPair();
  const signatureAlgorithm = sequence([der(6, new Uint8Array([42,134,72,134,247,13,1,1,11])), der(5,new Uint8Array(0))]);
  const name = sequence([der(49, sequence([der(6,new Uint8Array([85,4,3])),der(12,ascii('HSend'))]))]);
  const serial = (await cryptoFramework.createRandom().generateRandom(16)).data;
  serial[0] = (serial[0] & 0x7f) | 1;
  const tbs = sequence([der(160,der(2,new Uint8Array([2]))), der(2,serial), signatureAlgorithm, name,
    sequence([der(23,ascii('200101000000Z')),der(24,ascii('20991231235959Z'))]),name,pair.pubKey.getEncoded().data]);
  const signer = cryptoFramework.createSign('SHA256|RSA|PKCS1');
  await signer.init(pair.priKey);
  const signature = await signer.sign({data:tbs});
  const encoded = sequence([tbs,signatureAlgorithm,der(3,joinBytes([new Uint8Array([0]),signature.data]))]);
  const identity: DeviceIdentity = {certificate:pem('CERTIFICATE',encoded),key:pair.priKey.getEncodedPem('PKCS8'),fingerprint:await fingerprint(encoded)};
  pair.priKey.clearMem();
  return identity;
}

export async function loadOrCreateIdentity(context: common.UIAbilityContext): Promise<DeviceIdentity> {
  const prefs = await preferences.getPreferences(context, {name:'hsend_identity'});
  const saved = await prefs.get('identity','') as string;
  if (saved.length > 0) return JSON.parse(saved) as DeviceIdentity;
  const identity = await createIdentity();
  await prefs.put('identity', JSON.stringify(identity));
  await prefs.flush();
  return identity;
}
