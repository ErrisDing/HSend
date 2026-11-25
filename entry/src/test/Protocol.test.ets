import { describe, it, expect } from '@ohos/hypium';
import { hexFingerprint, layoutMode, safeName } from '../main/ets/model/Protocol';
import { formatFileProgress, formatFileSize } from '../main/ets/pages/FileSize';
export default function protocolTests() {
  describe('Protocol', () => {
    it('displays_decimal_file_sizes_and_progress', 0, () => {
      expect(formatFileSize(0)).assertEqual('0 B');
      expect(formatFileSize(999)).assertEqual('999 B');
      expect(formatFileSize(1000)).assertEqual('1.0 KB');
      expect(formatFileSize(1000000)).assertEqual('1.0 MB');
      expect(formatFileSize(1000000000)).assertEqual('1.0 GB');
      expect(formatFileProgress(12500,67108864)).assertEqual('12.5 KB / 67.1 MB');
    });
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
