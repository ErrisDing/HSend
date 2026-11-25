import { describe, it, expect } from '@ohos/hypium';
import { hexFingerprint, layoutMode, safeName } from '../main/ets/model/Protocol';
export default function protocolTests() {
  describe('Protocol', () => {
    it('formats_digest_as_uppercase_hex', 0, () => {
      expect(hexFingerprint(new Uint8Array([0, 15, 128, 255]))).assertEqual('000F80FF');
    });
    it('unwraps_path_components', 0, () => {
      expect(safeName('../照片.jpg')).assertEqual('照片.jpg');
      expect(safeName('..')).assertEqual('file');
    });
    it('uses_localsend_breakpoints', 0, () => {
      expect(layoutMode(699)).assertEqual(0);
      expect(layoutMode(700)).assertEqual(1);
      expect(layoutMode(800)).assertEqual(2);
    });
  });
}
