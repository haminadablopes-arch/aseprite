import * as P from './pipeline.js';
// ground truth 48x64 com famílias tonais (espelha fixture Python)
const W=48,H=64;
const PAL=[[245,245,250],[210,210,222],[20,20,30],[44,46,66],[30,32,48],[18,18,28],[110,70,45],[230,190,120],[250,250,252],[60,62,88]];
function frame(f){
  const g=new Uint8ClampedArray(W*H*4);
  const put=(y,x,c)=>{ if(y<0||x<0||y>=H||x>=W)return; const i=(y*W+x)*4; g[i]=PAL[c][0];g[i+1]=PAL[c][1];g[i+2]=PAL[c][2];g[i+3]=255; };
  const bob=f%2;
  for(let y=6;y<28;y++)for(let x=12;x<34;x++){
    const d1=Math.hypot(y-17,x-23), d2=Math.hypot(y-20,x-26.5);
    if(d1<10&&d2>8.2) put(y+bob,x,((y+x)%7)?0:1);
  }
  put(16+bob,20,2);put(16+bob,21,2);put(16+bob,24,2);
  for(let y=27;y<52;y++){
    const t=(y-27)/24, half=5+t*9+1.5*Math.sin(f*1.3)*t, cx=22+t*1.5;
    for(let x=Math.floor(cx-half);x<=Math.floor(cx+half);x++){
      const e=Math.abs(x-cx)/Math.max(1e-6,half);
      let c=e>0.82?3:(e>0.55?4:5); if(y<30)c=9;
      const fam={3:[3,4,5,9],4:[4,3,9,5],5:[5,4,3,9],9:[9,3,4,5]}[c];
      const hsh=(x*7+y*13+f*5)%5; if(hsh<2)c=fam[(x+y*3+f)%4];
      put(y+bob,x,c);
    }
  }
  for(let t=0;t<40;t++){ const y=Math.floor(24+t/40*32), x=Math.floor(36-t/40*4); put(y+bob,x,6); }
  const ph=[0,1,2,1][f%4];
  for(let k=0;k<8;k++){ put(52+k+bob,19+Math.floor(k/3)*(ph!==1?1:-1),2); put(52+k+bob,26-Math.floor(k/3)*(ph!==0?1:-1),2); }
  return g;
}
function degrade(gt,pitch,ox,oy,cw,ch,seed){
  const gw=Math.round(W*pitch), gh=Math.round(H*pitch);
  const out=new Uint8ClampedArray(cw*ch*4);
  for(let i=0;i<cw*ch;i++){ out[i*4]=10; out[i*4+1]=226; out[i*4+2]=70; out[i*4+3]=255; }
  let s=seed;
  const rnd=()=>((s=(s*1103515245+12345)&0x7fffffff)/0x7fffffff-0.5);
  for(let y=0;y<gh;y++)for(let x=0;x<gw;x++){
    const sx=Math.floor(x/pitch), sy=Math.floor(y/pitch);
    const si=(sy*W+sx)*4, di=((y+oy)*cw+(x+ox))*4;
    if(gt[si+3]>0){
      for(let c=0;c<3;c++) out[di+c]=Math.max(0,Math.min(255,gt[si+c]+Math.round(rnd()*8)));
      out[di+3]=255;
    }
  }
  return out;
}
const gts=[0,1,2,3].map(frame);
const srcs=gts.map((g,i)=>degrade(g,9.4,37,53,700,760,10+i));
const kd=P.detectChromaKey(srcs[0],700,760);
console.log('chroma', kd);
if(kd) srcs.forEach(s=>P.chromaKey(s,700,760,kd.key,90));
let g=P.detectGrid(srcs[0],700,760);
console.log('grid', g.px.toFixed(3), g.py.toFixed(3), g.ox.toFixed(2), g.oy.toFixed(2), 'conf', g.conf.toFixed(2));
g=P.refineAlignment(srcs[0],700,760,g);
g=P.refineGridCompact(srcs[0],700,760,g);
console.log('refinada', g.px.toFixed(3), g.py.toFixed(3), g.ox.toFixed(2), g.oy.toFixed(2));
const natives=srcs.map(s=>P.resampleNative(s,700,760,g));
console.log('nativo', natives[0].w, 'x', natives[0].h);
const pal=P.exactPalette(natives,32);
console.log('paleta exata:', pal? pal.length : 'null');
const P2=pal||P.kmeansOklab(natives,12);
let acc=0,tot=0;
natives.forEach((nat,f)=>{
  const sn=P.snapToPalette(nat,P2);
  const cl=P.removeOrphans(sn,1);
  // bbox compare
  let minx=1e9,miny=1e9,maxx=-1,maxy=-1;
  for(let y=0;y<cl.h;y++)for(let x=0;x<cl.w;x++) if(cl.data[(y*cl.w+x)*4+3]){ minx=Math.min(minx,x);maxx=Math.max(maxx,x);miny=Math.min(miny,y);maxy=Math.max(maxy,y); }
  const gt=gts[f]; let gminx=1e9,gminy=1e9,gmaxx=-1,gmaxy=-1;
  for(let y=0;y<H;y++)for(let x=0;x<W;x++) if(gt[(y*W+x)*4+3]){ gminx=Math.min(gminx,x);gmaxx=Math.max(gmaxx,x);gminy=Math.min(gminy,y);gmaxy=Math.max(gmaxy,y); }
  const w=Math.min(maxx-minx+1,gmaxx-gminx+1), h=Math.min(maxy-miny+1,gmaxy-gminy+1);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){
    const a=( (miny+y)*cl.w+(minx+x) )*4, b=((gminy+y)*W+(gminx+x))*4;
    if(gt[b+3]>0){ tot++;
      const ok=Math.abs(cl.data[a]-gt[b])<=8&&Math.abs(cl.data[a+1]-gt[b+1])<=8&&Math.abs(cl.data[a+2]-gt[b+2])<=8;
      if(ok)acc++; }
  }
});
console.log('fidelidade JS: %s%', (100*acc/tot).toFixed(1));
