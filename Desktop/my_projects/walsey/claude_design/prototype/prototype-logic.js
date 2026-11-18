// Canvas state logic shared by all screens (stage flags s0..s5, LED picker, HEX/RGB sync).
// Port to Flutter state (e.g. Riverpod/Bloc): stage int, color, brightness, saved.
class Component extends DCLogic{
state={s:0,hex:'#7B6CF6',ht:'#7B6CF6',rt:null,b:70,saved:false};
renderVals(){const t=this,s=this.state,o={};
for(let i=0;i<6;i++){o['s'+i]=s.s===i;o['st'+i]=()=>t.setState({s:i});}
const rgb=[1,3,5].map(i=>parseInt(s.hex.substr(i,2),16)),x2=n=>n.toString(16).padStart(2,'0');
o.hex=s.hex;o.ht=s.ht;o.b=s.b;o.op=s.b/100;o.saved=s.saved;o.unsaved=!s.saved;o.rgbv=s.rt!==null?s.rt:rgb.join(', ');
o.pick=e=>{const r=e.currentTarget.getBoundingClientRect(),R=r.width/2,x=e.clientX-r.left-R,y=e.clientY-r.top-R,d=Math.min(Math.hypot(x,y)/R,1),h=(Math.atan2(y,x)*57.2958+450)%360,l=1-0.5*d,a=Math.min(l,1-l),f=n=>{const k=(n+h/30)%12;return Math.round(255*(l-a*Math.max(-1,Math.min(k-3,9-k,1))))},c='#'+[f(0),f(8),f(4)].map(x2).join('');t.setState({hex:c,ht:c,rt:null,saved:false});};
o.setHex=e=>{const v=e.target.value;t.setState(/^#[0-9a-f]{6}$/i.test(v)?{hex:v,ht:v,rt:null,saved:false}:{ht:v});};
o.setRgb=e=>{const v=e.target.value,m=v.split(',').map(Number);t.setState(m.length===3&&m.every(n=>n>=0&&n<=255)&&v.trim().slice(-1)!==','?{hex:'#'+m.map(x2).join(''),rt:v,saved:false}:{rt:v});};
o.setB=e=>t.setState({b:+e.target.value,saved:false});o.save=()=>t.setState({saved:true});
['#7B6CF6','#3DD6E8','#4CC38A','#F2B04A'].forEach((c,i)=>o['c'+i]=()=>t.setState({hex:c,ht:c,rt:null}));
return o;}}
