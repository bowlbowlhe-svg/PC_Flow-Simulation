// 测试用的最小 PNG 解码（8 位灰度 / RGB、非隔行，五种行滤波），返回 RGBA（同 canvas getImageData）。
import { inflateSync } from 'node:zlib';

export function decodePng(b64: string): { w: number; h: number; rgba: Uint8ClampedArray } {
  const buf = Buffer.from(b64, 'base64');
  let p = 8;
  let w = 0;
  let h = 0;
  let ch = 0;
  const idat: Buffer[] = [];
  while (p < buf.length) {
    const len = buf.readUInt32BE(p);
    const type = buf.toString('ascii', p + 4, p + 8);
    const data = buf.subarray(p + 8, p + 8 + len);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0);
      h = data.readUInt32BE(4);
      if (data[8] !== 8 || data[12] !== 0) throw new Error('只支持 8 位、非隔行');
      ch = data[9] === 2 ? 3 : data[9] === 0 ? 1 : 0;
      if (!ch) throw new Error('只支持灰度与 RGB');
    } else if (type === 'IDAT') idat.push(data);
    p += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat));
  const rb = ch * w;
  const px = new Uint8Array(h * rb);
  for (let r = 0; r < h; r++) {
    const f = raw[r * (rb + 1)];
    for (let k = 0; k < rb; k++) {
      const x = raw[r * (rb + 1) + 1 + k];
      const a = k >= ch ? px[r * rb + k - ch] : 0;
      const b = r ? px[(r - 1) * rb + k] : 0;
      const c = r && k >= ch ? px[(r - 1) * rb + k - ch] : 0;
      let v: number;
      if (f === 0) v = x;
      else if (f === 1) v = x + a;
      else if (f === 2) v = x + b;
      else if (f === 3) v = x + ((a + b) >> 1);
      else {
        const pp = a + b - c;
        const pa = Math.abs(pp - a);
        const pb = Math.abs(pp - b);
        const pc = Math.abs(pp - c);
        v = x + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c);
      }
      px[r * rb + k] = v & 0xff;
    }
  }
  const rgba = new Uint8ClampedArray(w * h * 4);
  for (let k = 0; k < w * h; k++) {
    for (let q = 0; q < 3; q++) rgba[4 * k + q] = px[k * ch + (ch === 3 ? q : 0)];
    rgba[4 * k + 3] = 255;
  }
  return { w, h, rgba };
}
