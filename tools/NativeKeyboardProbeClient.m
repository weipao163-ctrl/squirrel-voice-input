#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>

// The legacy IMK initializer requires its actual Foundation proxy class.
// Wrap only the test client's local object; never connect to a real application.
id KeyboardProbeWrapClient(id client) {
  NSConnection *connection = [NSConnection new];
  id proxy = [NSDistantObject proxyWithLocal:client connection:connection];
  [proxy setProtocolForProxy:@protocol(IMKTextInput)];
  return proxy;
}
