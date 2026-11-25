// LocalSend displays decimal units (1 KB = 1000 B) with one fractional digit.
export function formatFileSize(bytes: number): string {
  if (bytes < 1000) return bytes + ' B';
  if (bytes < 1000000) return (bytes / 1000).toFixed(1) + ' KB';
  if (bytes < 1000000000) return (bytes / 1000000).toFixed(1) + ' MB';
  return (bytes / 1000000000).toFixed(1) + ' GB';
}

export function formatFileProgress(done: number, total: number): string {
  return formatFileSize(done) + ' / ' + formatFileSize(total);
}
