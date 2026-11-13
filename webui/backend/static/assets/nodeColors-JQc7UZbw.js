function n(e){let o=5381;for(let t=0;t<e.length;t+=1)o=(o<<5)+o+e.charCodeAt(t)|0;return`var(--sd-node-${Math.abs(o)%10+1})`}export{n};
