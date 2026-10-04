import { pathToFileURL } from 'node:url';
import { join, resolve } from 'node:path';
import { readFile } from 'node:fs/promises';

export async function activateInstallation(api, options) {
 return api.withRegistryLock(options.dshHome, async () => {
  const installed = await api.installGeneration({...options,
   pluginSpec: 'boring-notch-dsh@0.3.0', expectedPluginName: 'boring-notch-dsh', expectedVersion: '0.3.0'});
  if (!installed.ok || !installed.generation) throw Error('installation-failed');
  const previous = await api.readDesired(options.dshHome);
  const generations = new Map((await api.listGenerations(options.dshHome)).map(g=>[g.id,g]));
  const retained = previous.filter(id=>generations.get(id)?.pluginName !== 'boring-notch-dsh');
  await api.writeDesired(options.dshHome,[...retained,installed.generation.id]);
  try {
   await api.publishInstalledGeneration(options.dshHome,'boring-notch-dsh','web',{
    allowRealDirectory: options.allowRealDirectory === true, syncBundles:true});
  } catch(error) {
   await api.writeDesired(options.dshHome,previous);
   throw error;
  }
 });
}
async function main() {
 const [runtime, sourceDirectory, dshHome, stopped] = process.argv.slice(2);
 if (!runtime || !sourceDirectory || !dshHome) throw Error('arguments');
 const manifest = JSON.parse(await readFile(join(sourceDirectory,'package.json'),'utf8'));
 if (manifest.name !== 'boring-notch-dsh' || manifest.version !== '0.3.0') throw Error('package');
 const base=join(runtime,'node_modules','dsh-desktop-market-installer','generations');
 const [installer,registry,projection] = await Promise.all(['installer','registry','projection'].map(name=>import(pathToFileURL(join(base,name+'.mjs')).href)));
 await activateInstallation({...installer,...registry,...projection},{
  dshHome, sourceDirectory, allowRealDirectory:stopped==='stopped',
  nodeExecutablePath:process.execPath,
  pnpmEntryPath:join(runtime,'node_modules','pnpm','bin','pnpm.cjs'),
  profile:'web',
 });
 console.log('installed');
}
if (process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href) {
 main().catch(error=>{
  const code=String(error?.message).includes('Cannot switch a non-link plugin directory')?'quit-required':'failed';
  console.log(code); process.exitCode=1;
 });
}
