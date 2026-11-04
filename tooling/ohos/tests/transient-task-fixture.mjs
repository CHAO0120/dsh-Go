export const timers=new Map();let next=1;
export const setTimeout=(fn,ms)=>{const id=next++;timers.set(id,{fn,ms});return id;};
export const clearTimeout=id=>timers.delete(id);
export const osTask={requests:[],cancels:[],failCancel:false,callbackNow:false,duration:30000};
export const backgroundTaskManager={requestSuspendDelay(reason,callback){const id=next++;osTask.requests.push({id,reason,callback});if(osTask.callbackNow)callback();return{requestId:id,actualDelayTime:osTask.duration};},cancelSuspendDelay(id){osTask.cancels.push(id);if(osTask.failCancel)throw Error('OS cancel unavailable');}};
