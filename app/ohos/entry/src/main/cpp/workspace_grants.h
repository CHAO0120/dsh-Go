#ifndef DSH_WORKSPACE_GRANTS_H
#define DSH_WORKSPACE_GRANTS_H
// Trusted owner API, not a path permission API. No descriptor escapes a lease.
// Directory OBJECT leases: a host rename does not revoke the pinned object.
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <dirent.h>
#include <functional>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <system_error>
#include <vector>
namespace dsh {
class GrantError : public std::runtime_error {
 public: const std::string code;
  GrantError(const char* c):std::runtime_error(c),code(c){}
};
namespace grant_detail {
inline void Check(bool ok) { if(!ok) throw std::system_error(errno,std::generic_category(),"Workspace operation failed"); }
struct Fd {
 int fd; explicit Fd(int n):fd(n){Check(n>=0);} ~Fd(){if(fd>=0)close(fd);}
 Fd(const Fd&)=delete; Fd& operator=(const Fd&)=delete;
};
inline std::vector<std::string> Parts(const std::string& path){
 if(path.empty()||path.front()=='/'||path.find('\0')!=std::string::npos)throw GrantError("ERR_WORKSPACE_PATH");
 std::vector<std::string> out;size_t start=0;
 for(;;){auto end=path.find('/',start);auto part=path.substr(start,end==std::string::npos?end:end-start);
  if(part.empty()||part=="."||part=="..")throw GrantError("ERR_WORKSPACE_PATH");
  out.push_back(part);if(end==std::string::npos)return out;start=end+1;
 }
}
struct State {
 std::mutex mutex; int root=-1; uint64_t generation=0;bool writable=false,active=true,close_failed=false;size_t leases=0;
 ~State(){if(root>=0)close(root);}
 void CheckActive(bool write){if(!active)throw GrantError("ERR_WORKSPACE_RETIRED");if(close_failed)throw GrantError("ERR_WORKSPACE_CLOSE_FAILED");if(write&&!writable)throw GrantError("ERR_WORKSPACE_READ_ONLY");}
};
inline int Parent(int root,const std::vector<std::string>& parts){
 Fd cursor(fcntl(root,F_DUPFD_CLOEXEC,0));
 for(size_t i=0;i+1<parts.size();++i){Fd next(openat(cursor.fd,parts[i].c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC));
  const int old=cursor.fd;cursor.fd=next.fd;next.fd=old;}
 const int result=cursor.fd;cursor.fd=-1;return result;
}
inline void Regular(int fd){struct stat st{};Check(fstat(fd,&st)==0);if(!S_ISREG(st.st_mode))throw GrantError("ERR_WORKSPACE_FILE_TYPE");}
struct TaskScope { std::shared_ptr<State> state;bool active=true;bool live=true; };
}
struct WorkspaceGrantStatus { bool active;bool drained;bool writable;size_t leases;uint64_t generation; };
class WorkspaceLease {
 std::shared_ptr<grant_detail::State> state_;bool write_;
 std::shared_ptr<grant_detail::TaskScope> task_;
 friend class WorkspaceGrants;
 friend class WorkspaceFid;
 WorkspaceLease(std::shared_ptr<grant_detail::State> state,bool write):state_(std::move(state)),write_(write){++state_->leases;}
 void Access(bool write){state_->CheckActive(write);if(task_&&!task_->active)throw GrantError("ERR_WORKSPACE_TASK_RETIRED");if(write&&!write_)throw GrantError("ERR_WORKSPACE_READ_ONLY");}
 public:
 WorkspaceLease(const WorkspaceLease&)=delete;WorkspaceLease& operator=(const WorkspaceLease&)=delete;
 ~WorkspaceLease(){std::lock_guard<std::mutex> lock(state_->mutex);--state_->leases;if(task_)task_->live=false;}
 std::shared_ptr<grant_detail::TaskScope> Task(){std::lock_guard<std::mutex> lock(state_->mutex);
  if(!task_)task_=std::make_shared<grant_detail::TaskScope>(grant_detail::TaskScope{state_,true,true});
  return task_;}
 struct stat Stat(const std::string& path){std::lock_guard<std::mutex> lock(state_->mutex);Access(false);struct stat st{};
  if(path.empty()){grant_detail::Check(fstat(state_->root,&st)==0);return st;}
  auto parts=grant_detail::Parts(path);grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
  grant_detail::Check(fstatat(parent.fd,parts.back().c_str(),&st,AT_SYMLINK_NOFOLLOW)==0);return st;
 }
 void Readdir(const std::string& path,const std::function<void(const std::string&)>& emit){
  std::lock_guard<std::mutex> lock(state_->mutex);Access(false);
  int fd;
  if(path.empty())fd=openat(state_->root,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  else {auto parts=grant_detail::Parts(path);grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
    fd=openat(parent.fd,parts.back().c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);}
  grant_detail::Fd owned(fd);DIR* raw=fdopendir(fd);grant_detail::Check(raw!=nullptr);owned.fd=-1;
  std::unique_ptr<DIR,int(*)(DIR*)> directory(raw,closedir);size_t count=0;
  for(;;){errno=0;auto* entry=readdir(raw);if(!entry){grant_detail::Check(errno==0);break;}
    std::string name=entry->d_name;if(name=="."||name=="..")continue;
    if(++count>10000)throw GrantError("ERR_WORKSPACE_LIMIT");
    emit(name);}
 }
 std::string Read(const std::string& path,uint64_t offset,size_t maximum){
  if(maximum>1024*1024||offset>INT64_MAX)throw GrantError("ERR_WORKSPACE_LIMIT");
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(false);
  grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
  grant_detail::Fd file(openat(parent.fd,parts.back().c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));grant_detail::Regular(file.fd);
  std::string result(maximum,'\0');auto count=pread(file.fd,result.data(),maximum,static_cast<off_t>(offset));grant_detail::Check(count>=0);result.resize(count);return result;
 }
 size_t Write(const std::string& path,const std::string& bytes,uint64_t offset,bool create=false,bool truncate=false,bool append=false,bool exclusive=false){
  if(bytes.size()>1024*1024||offset>INT64_MAX)throw GrantError("ERR_WORKSPACE_LIMIT");
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
  // Never truncate before checking the opened object's type.
  grant_detail::Fd file(openat(parent.fd,parts.back().c_str(),O_WRONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK|(create?O_CREAT:0)|(append?O_APPEND:0)|(exclusive?O_EXCL:0),0600));
  grant_detail::Regular(file.fd);if(truncate)grant_detail::Check(ftruncate(file.fd,0)==0);
  auto count=append?write(file.fd,bytes.data(),bytes.size()):pwrite(file.fd,bytes.data(),bytes.size(),static_cast<off_t>(offset));grant_detail::Check(count>=0);return count;
 }
 void Rename(const std::string& source,const std::string& destination){
  auto from=grant_detail::Parts(source),to=grant_detail::Parts(destination);
  std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  grant_detail::Fd a(grant_detail::Parent(state_->root,from)),b(grant_detail::Parent(state_->root,to));
  grant_detail::Check(renameat(a.fd,from.back().c_str(),b.fd,to.back().c_str())==0);
 }
 void Remove(const std::string& path,bool directory=false){
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));
  grant_detail::Check(unlinkat(parent.fd,parts.back().c_str(),directory?AT_REMOVEDIR:0)==0);
 }
 void Mkdir(const std::string& path){
  auto parts=grant_detail::Parts(path);std::lock_guard<std::mutex> lock(state_->mutex);Access(true);
  grant_detail::Fd parent(grant_detail::Parent(state_->root,parts));grant_detail::Check(mkdirat(parent.fd,parts.back().c_str(),0700)==0);
 }
};
class WorkspaceGrants {
 std::mutex mutex_;std::map<std::string,std::shared_ptr<grant_detail::State>> grants_;
 static WorkspaceGrantStatus Snapshot(const grant_detail::State& s){return {s.active,!s.active&&s.root<0&&s.leases==0&&!s.close_failed,s.writable,s.leases,s.generation};}
 std::shared_ptr<grant_detail::State> Find(const std::string& id,uint64_t generation){auto found=grants_.find(id);
  if(found==grants_.end()||found->second->generation!=generation)throw GrantError("ERR_WORKSPACE_GENERATION");
  return found->second;}
 public:
 // Ark alone calls this after opening the actual picker/activated URI. The fd
 // is borrowed and duplicated; URI conversion and Dart input never reach here.
 void Publish(const std::string& id,uint64_t generation,int descriptor,bool writable){
  if(id.empty()||id.size()>128||id.find('\0')!=std::string::npos||generation==0)throw GrantError("ERR_WORKSPACE_ID");
  struct stat st{};grant_detail::Check(fstat(descriptor,&st)==0);if(!S_ISDIR(st.st_mode))throw GrantError("ERR_WORKSPACE_DIRECTORY");
  std::lock_guard<std::mutex> owner(mutex_);auto prior=grants_.find(id);
  if(prior!=grants_.end()){std::lock_guard<std::mutex> lock(prior->second->mutex);
   if(generation<=prior->second->generation)throw GrantError("ERR_WORKSPACE_GENERATION");
   if(!Snapshot(*prior->second).drained)throw GrantError("ERR_WORKSPACE_DRAINING");}
  if(prior==grants_.end()&&grants_.size()>=128)throw GrantError("ERR_WORKSPACE_LIMIT");
  auto state=std::make_shared<grant_detail::State>();state->root=fcntl(descriptor,F_DUPFD_CLOEXEC,0);grant_detail::Check(state->root>=0);
  state->generation=generation;state->writable=writable;grants_[id]=state;
 }
 std::unique_ptr<WorkspaceLease> Acquire(const std::string& id,uint64_t generation,bool write){
  std::lock_guard<std::mutex> owner(mutex_);auto state=Find(id,generation);std::lock_guard<std::mutex> lock(state->mutex);state->CheckActive(write);
  return std::unique_ptr<WorkspaceLease>(new WorkspaceLease(state,write));
 }
 WorkspaceGrantStatus Retire(const std::string& id,uint64_t generation){
  std::lock_guard<std::mutex> owner(mutex_);auto state=Find(id,generation);std::lock_guard<std::mutex> lock(state->mutex);
  state->active=false;if(state->root>=0){int descriptor=state->root;state->root=-1;if(close(descriptor)!=0)state->close_failed=true;}
  return Snapshot(*state);
 }
 struct Record {std::string id;uint64_t generation;bool writable;};
 std::vector<Record> SnapshotActive(){std::vector<Record> records;std::lock_guard<std::mutex> owner(mutex_);
  for(auto& pair:grants_){auto& state=*pair.second;std::lock_guard<std::mutex> lock(state.mutex);
   if(state.active)records.push_back({pair.first,state.generation,state.writable});}
  return records;
 }
 WorkspaceGrantStatus Status(const std::string& id,uint64_t generation){std::lock_guard<std::mutex> owner(mutex_);auto state=Find(id,generation);
  std::lock_guard<std::mutex> lock(state->mutex);return Snapshot(*state);}
};
// One owner instance in libdsh_host; consumers must link this symbol, never instantiate another registry.
WorkspaceGrants& WorkspaceGrantOwner();
}
#endif
