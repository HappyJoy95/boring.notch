import { test } from 'node:test';
import assert from 'node:assert/strict';
import { activateInstallation } from '../../Integrations/DSHDesktop/install.mjs';
const setup = (fail = false) => {
 const state = {desired:['other','old'], options:null};
 const api = {
 withRegistryLock: async (_, fn) => fn(),
 installGeneration: async options => { state.options=options; return {ok:true,generation:{id:'new',pluginName:'boring-notch-dsh'}}; },
 readDesired: async () => [...state.desired],
 listGenerations: async () => [{id:'other',pluginName:'other'},{id:'old',pluginName:'boring-notch-dsh'}],
 writeDesired: async (_, ids) => {state.desired=ids;},
 publishInstalledGeneration: async () => {if(fail)throw Error('fail');},
 };
 return {api,state};
};
test('replaces only this plugin and enables installed generation',async()=>{
 const {api,state}=setup();
 await activateInstallation(api,{dshHome:'/home',sourceDirectory:'/source'});
 assert.deepEqual(state.desired,['other','new']);
 assert.equal(state.options.expectedPluginName,'boring-notch-dsh');
 assert.equal(state.options.expectedVersion,'0.3.0');
});
test('publication failure restores previous desired generations',async()=>{
 const {api,state}=setup(true);
 await assert.rejects(activateInstallation(api,{dshHome:'/home',sourceDirectory:'/source'}));
 assert.deepEqual(state.desired,['other','old']);
});
test('failed installation does not change activation',async()=>{
 const {api,state}=setup();api.installGeneration=async()=>({ok:false});
 await assert.rejects(activateInstallation(api,{dshHome:'/home',sourceDirectory:'/source'}));
 assert.deepEqual(state.desired,['other','old']);
});
