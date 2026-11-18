const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch();
for(const sc of [1,2]){const p=await b.newPage({viewport:{width:1300,height:800},deviceScaleFactor:sc});
await p.goto('file://'+process.cwd()+'/gallery.html');await p.waitForLoadState('networkidle');
const names=['1-cover','2-how-it-works','3-claude-code','4-app','5-limits'];
for(let i=0;i<5;i++){await p.locator('#s'+(i+1)).screenshot({path:'out/'+names[i]+(sc==2?'@2x':'')+'.png'});}
await p.close();}
await b.close();})();
