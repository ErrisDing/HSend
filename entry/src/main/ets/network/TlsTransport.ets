import { socket } from '@kit.NetworkKit';
import { Peer } from '../model/Protocol';
import { DeviceIdentity, fingerprint, pem } from './Identity';
import { cert } from '@kit.DeviceCertificateKit';
import { HttpConnection } from './HttpConnection';

export async function connectPeer(peer: Peer, identity: DeviceIdentity, remember?: (certificate: string) => void): Promise<HttpConnection> {
  const wire = socket.constructTLSSocketInstance();
  const timeout = setTimeout(() => { wire.close().catch(() => {}); },10000);
  try {
    await wire.bind({address:'0.0.0.0',port:0,family:1});
    // LocalSend peers use per-installation self-signed certificates. Verify the
    // advertised fingerprint on this connection before sending application data.
    await wire.connect({address:{address:peer.address,port:peer.info.port,family:1},
      secureOptions:{cert:identity.certificate,key:identity.key},skipRemoteValidation:true,
      ALPNProtocols:['http/1.1']});
    const parsed = await cert.createX509Cert(await wire.getRemoteCertificate());
    const bytes = (await parsed.getEncoded()).data;
    if (await fingerprint(bytes) !== peer.info.fingerprint.toUpperCase()) {
      throw new Error('设备证书指纹不匹配');
    }
    if (remember) remember(pem('CERTIFICATE',bytes));
    return HttpConnection.fromSocket(wire);
  } catch (e) { await wire.close().catch(() => {}); throw e as Error; }
  finally { clearTimeout(timeout); }
}
