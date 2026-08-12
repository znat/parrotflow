#import "ObjCExceptions.h"

NSException *_Nullable PFRunCatchingObjCExceptions(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
