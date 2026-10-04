import { startBridge } from '../boring-notch-bridge/runtime.mjs';
import { fileURLToPath } from 'node:url';
// One server per MiMo engine process, even when the plugin loads for many workspaces.
const key=Symbol.for('boring-notch-mimo-bridge.0.1.0');
export default async function BoringNotchMiMoBridge(input){
 // CLI instances share the plugin directory; only the desktop host may own this bridge.
 if(!process.versions.electron)return {};
 if(!globalThis[key]){
  globalThis[key]=startBridge(input,fileURLToPath(new URL('../boring-notch-bridge/config.json',import.meta.url)))
   .catch(error=>{delete globalThis[key];throw error;});
 }
 const bridge=await globalThis[key];bridge.runtime.attach(input);
 return {event:({event})=>bridge.runtime.event(event)};
}
