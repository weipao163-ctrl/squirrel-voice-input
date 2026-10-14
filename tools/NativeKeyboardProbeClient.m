#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <mach/mach.h>
#import <sys/resource.h>

// The legacy IMK initializer requires its actual Foundation proxy class.
// Wrap only the test client's local object; never connect to a real application.
id KeyboardProbeWrapClient(id client) {
  NSConnection *connection = [NSConnection new];
  id proxy = [NSDistantObject proxyWithLocal:client connection:connection];
  [proxy setProtocolForProxy:@protocol(IMKTextInput)];
  return proxy;
}

// Process counters for the isolated workload. No other process is inspected.
NSDictionary<NSString *, NSNumber *> *KeyboardProbeProcessMetrics(void) {
  struct rusage usage = {0};
  getrusage(RUSAGE_SELF, &usage);
  task_vm_info_data_t vm = {0};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO,
                                  (task_info_t)&vm, &count);
  return @{@"cpu_seconds": @(usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
                            usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6),
           @"resident_bytes": @(vm.resident_size),
           @"physical_footprint_bytes": @(vm.phys_footprint),
           @"memory_counter_status": @(status)};
}
