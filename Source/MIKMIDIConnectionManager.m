//
//  MIKMIDIConnectionManager.m
//  MIKMIDI
//
//  Created by Andrew Madsen on 11/5/15.
//  Copyright © 2015 Mixed In Key. All rights reserved.
//

#import "MIKMIDIConnectionManager.h"
#import "MIKMIDIDeviceManager.h"
#import "MIKMIDIDevice.h"

void *MIKMIDIConnectionManagerKVOContext = &MIKMIDIConnectionManagerKVOContext;

NSString * const MIKMIDIConnectionManagerConnectedDevicesKey = @"MIKMIDIConnectionManagerConnectedDevicesKey";

@interface MIKMIDIConnectionManager ()

@property (nonatomic, strong, readwrite) MIKArrayOf(MIKMIDIDevice *) *availableDevices;

@property (nonatomic, strong, readonly) MIKMutableSetOf(MIKMIDIDevice *) *internalConnectedDevices;
@property (nonatomic, strong, readonly) MIKMIDIEventHandlerBlock internalEventHandler;
@property (nonatomic, strong, readonly) MIKMapTableOf(MIKMIDIDevice *, id) *connectionTokensByDevice;

@property (nonatomic, readonly) MIKMIDIDeviceManager *deviceManager;

@end

@implementation MIKMIDIConnectionManager

- (instancetype)init
{
	[NSException raise:NSInternalInconsistencyException format:@"-initWithName: is the designated initializer for %@", NSStringFromClass([self class])];
	return nil;
}

- (instancetype)initWithName:(NSString *)name
{
	self = [super init];
	if (self) {
		_name = [name copy];
		_internalConnectedDevices = [[NSMutableSet alloc] init];
		
		__weak typeof(self) weakSelf = self;
		_internalEventHandler = ^(MIKMIDISourceEndpoint *endpoint, NSArray *commands) {
			weakSelf.eventHandler(endpoint, commands);
		};
		
		_connectionTokensByDevice = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsStrongMemory];
		
		NSKeyValueObservingOptions options = NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld;
		[self.deviceManager addObserver:self forKeyPath:@"availableDevices" options:options context:MIKMIDIConnectionManagerKVOContext];
		[self.deviceManager addObserver:self forKeyPath:@"virtualSources" options:options context:MIKMIDIConnectionManagerKVOContext];
		[self.deviceManager addObserver:self forKeyPath:@"virtualDestinations" options:options context:MIKMIDIConnectionManagerKVOContext];
		
		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserver:self selector:@selector(deviceWasPluggedIn:) name:MIKMIDIDeviceWasAddedNotification object:nil];
		[nc addObserver:self selector:@selector(deviceWasUnplugged:) name:MIKMIDIDeviceWasRemovedNotification object:nil];
		[nc addObserver:self selector:@selector(endpointWasPluggedIn:) name:MIKMIDIVirtualEndpointWasAddedNotification object:nil];
		[nc addObserver:self selector:@selector(endpointWasUnplugged:) name:MIKMIDIVirtualEndpointWasRemovedNotification object:nil];
	}
	return self;
}

- (void)dealloc
{
	[self.deviceManager removeObserver:self forKeyPath:@"availableDevices" context:MIKMIDIConnectionManagerKVOContext];
	[self.deviceManager removeObserver:self forKeyPath:@"virtualSources" context:MIKMIDIConnectionManagerKVOContext];
	[self.deviceManager removeObserver:self forKeyPath:@"virtualDestinations" context:MIKMIDIConnectionManagerKVOContext];
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Public

#pragma mark Device Connection / Disconnection

- (BOOL)connectToDevice:(MIKMIDIDevice *)device error:(NSError **)error
{
	if ([self isConnectedToDevice:device]) return YES;
	error = error ?: &(NSError *__autoreleasing){ nil };
	
	id token = [self.deviceManager connectDevice:device error:error eventHandler:self.internalEventHandler];
	if (!token) return NO;
	
	[self.connectionTokensByDevice setObject:token forKey:device];
	
	if (self.automaticallySavesConfiguration) [self saveConfiguration];
	
	return YES;
}

- (void)disconnectFromDevice:(MIKMIDIDevice *)device
{
	if (![self isConnectedToDevice:device]) return;
	
	id token = [self.connectionTokensByDevice objectForKey:device];
	if (!token) return;
	
	[self.deviceManager disconnectConnectionforToken:token];
	
	if (self.automaticallySavesConfiguration) [self saveConfiguration];
}

- (BOOL)isConnectedToDevice:(MIKMIDIDevice *)device;
{
	return [self.connectedDevices containsObject:device];
}

#pragma mark Configuration Persistence

- (void)saveConfiguration
{
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	
	NSMutableDictionary *configuration = [NSMutableDictionary dictionaryWithDictionary:[self savedConfiguration]];
	
	// Save connected device names
	NSMutableArray *connectedDeviceNames = configuration[MIKMIDIConnectionManagerConnectedDevicesKey];
	if (!connectedDeviceNames) {
		connectedDeviceNames = [NSMutableArray array];
		configuration[MIKMIDIConnectionManagerConnectedDevicesKey] = connectedDeviceNames;
	}
	
	// For devices that were connected in saved configuration but are now unavailable, leave them
	// connected in the configuration so they'll reconnect automatically.
	for (MIKMIDIDevice *device in self.availableDevices) {
		NSString *name = device.name;
		if (![name length]) continue;
		if ([self isConnectedToDevice:device]) {
			[connectedDeviceNames addObject:name];
		} else {
			[connectedDeviceNames removeObject:name];
		}
	}
	
	[userDefaults setObject:configuration forKey:[self userDefaultsConfigurationKey]];
}

- (void)loadConfiguration
{
	for (MIKMIDIDevice *device in self.availableDevices) {
		if ([self deviceIsConnectedInSavedConfiguration:device]) {
			NSError *error = nil;
			if (![self connectToDevice:device error:&error]) {
				NSLog(@"Unable to connect to MIDI device %@: %@", device, error);
				return;
			}
		}
	}
}

#pragma mark - Private

- (void)updateAvailableDevices
{
	NSArray *regularDevices = self.deviceManager.availableDevices;
	NSMutableSet *result = [NSMutableSet setWithArray:regularDevices];
	
	if (self.includesVirtualDevices) {
		NSMutableSet *endpointsInDevices = [NSMutableSet set];
		for (MIKMIDIDevice *device in regularDevices) {
			NSSet *sources = [NSSet setWithArray:[device.entities valueForKeyPath:@"@distinctUnionOfArrays.sources"]];
			NSSet *destinations = [NSSet setWithArray:[device.entities valueForKeyPath:@"@distinctUnionOfArrays.destinations"]];
			[endpointsInDevices unionSet:sources];
			[endpointsInDevices unionSet:destinations];
		}
		
		NSMutableSet *devicelessSources = [NSMutableSet setWithArray:self.deviceManager.virtualSources];
		NSMutableSet *devicelessDestinations = [NSMutableSet setWithArray:self.deviceManager.virtualDestinations];
		[devicelessSources minusSet:endpointsInDevices];
		[devicelessDestinations minusSet:endpointsInDevices];
		
		// Now we need to try to associate each source with its corresponding destination on the same device
		NSMapTable *destinationToSourceMap = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableStrongMemory];
		NSMapTable *deviceNamesBySource = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory valueOptions:NSMapTableStrongMemory];
		
		for (MIKMIDIEndpoint *source in devicelessSources) {
			NSString *sourceName = [self deviceNameFromVirtualEndpoint:source];
			for (MIKMIDIEndpoint *destination in devicelessDestinations) {
				NSString *destinationName = [self deviceNameFromVirtualEndpoint:destination];
				if ([sourceName isEqualToString:destinationName]) { // Source and destination match
					[destinationToSourceMap setObject:destination forKey:source];
					[deviceNamesBySource setObject:sourceName forKey:source];
					break;
				}
			}
		}
		
		for (MIKMIDIEndpoint *source in destinationToSourceMap) {
			MIKMIDIEndpoint *destination = [destinationToSourceMap objectForKey:source];
			[devicelessSources removeObject:source];
			[devicelessDestinations removeObject:destination];
			
			MIKMIDIDevice *device = [MIKMIDIDevice deviceWithVirtualEndpoints:@[source, destination]];
			device.name = [deviceNamesBySource objectForKey:source];
			if (device) [result addObject:device];
		}
		for (MIKMIDIEndpoint *endpoint in devicelessSources) {
			MIKMIDIDevice *device = [MIKMIDIDevice deviceWithVirtualEndpoints:@[endpoint]];
			if (device) [result addObject:device];
		}
		for (MIKMIDIEndpoint *endpoint in devicelessSources) {
			MIKMIDIDevice *device = [MIKMIDIDevice deviceWithVirtualEndpoints:@[endpoint]];
			if (device) [result addObject:device];
		}
	}
	
	self.availableDevices = [result copy];
}

- (MIKMIDIDevice *)firstAvailableDeviceWithName:(NSString *)deviceName
{
	NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name == %@", deviceName];
	return [[self.availableDevices filteredArrayUsingPredicate:predicate] firstObject];
}

- (void)connectToNewlyAddedDeviceIfAppropriate:(MIKMIDIDevice *)device
{
	if (!device) return;
	
	BOOL shouldConnect = [self deviceIsConnectedInSavedConfiguration:device];
	
	if ([self.delegate respondsToSelector:@selector(connectionManager:shouldConnectToNewlyAddedDevice:)]) {
		shouldConnect = [self.delegate connectionManager:self shouldConnectToNewlyAddedDevice:device];
	}
	
	if (shouldConnect) {
		NSError *error = nil;
		if (![self connectToDevice:device error:&error]) {
			NSLog(@"Unable to connect to MIDI device %@: %@", device, error);
			return;
		}
	}
}

#pragma mark Configuration Persistence

- (NSString *)userDefaultsConfigurationKey
{
	NSString *name = self.name;
	if (![name length]) name = NSStringFromClass([self class]);
	return [NSString stringWithFormat:@"%@SavedMIDIConnectionConfiguration", name];
}

- (NSDictionary *)savedConfiguration
{
	NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
	return [userDefaults objectForKey:[self userDefaultsConfigurationKey]];
}

- (BOOL)deviceIsConnectedInSavedConfiguration:(MIKMIDIDevice *)device
{
	NSString *deviceName = device.name;
	if (![deviceName length]) return NO;
	
	NSDictionary *configuration = [self savedConfiguration];
	NSArray *connectedDeviceNames = configuration[MIKMIDIConnectionManagerConnectedDevicesKey];
	return [connectedDeviceNames containsObject:deviceName];
}

#pragma mark Virtual Endpoints

- (NSString *)deviceNameFromVirtualEndpoint:(MIKMIDIEndpoint *)endpoint
{
	NSString *name = endpoint.name;
	if (![name length]) name = [endpoint description];
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceCharacterSet];
	NSMutableArray *nameComponents = [[name componentsSeparatedByCharactersInSet:whitespace] mutableCopy];
	[nameComponents removeLastObject];
	return [nameComponents componentsJoinedByString:@" "];
}

- (MIKMIDIDevice *)deviceContainingEndpoint:(MIKMIDIEndpoint *)endpoint
{
	if (!endpoint) return nil;
	NSMutableSet *devices = [self.availableDevices mutableCopy];
	[devices unionSet:self.connectedDevices];
	for (MIKMIDIDevice *device in devices) {
		NSMutableSet *deviceEndpoints = [NSMutableSet setWithArray:[device.entities valueForKeyPath:@"@distinctUnionOfArrays.sources"]];
		[deviceEndpoints unionSet:[NSSet setWithArray:[device.entities valueForKeyPath:@"@distinctUnionOfArrays.destinations"]]];
		if ([deviceEndpoints containsObject:endpoint]) return device;
	}
	return nil;
}

#pragma mark - Notifications

- (void)deviceWasPluggedIn:(NSNotification *)notification
{
	MIKMIDIDevice *device = [notification userInfo][MIKMIDIDeviceKey];
	[self connectToNewlyAddedDeviceIfAppropriate:device];
}

- (void)deviceWasUnplugged:(NSNotification *)notification
{
	MIKMIDIDevice *unpluggedDevice = [notification userInfo][MIKMIDIDeviceKey];
	[self disconnectFromDevice:unpluggedDevice];
}

- (void)endpointWasPluggedIn:(NSNotification *)notification
{
	MIKMIDIEndpoint *pluggedInEndpoint = [notification userInfo][MIKMIDIEndpointKey];
	MIKMIDIDevice *pluggedInDevice = [self deviceContainingEndpoint:pluggedInEndpoint];
	[self connectToNewlyAddedDeviceIfAppropriate:pluggedInDevice];
}

- (void)endpointWasUnplugged:(NSNotification *)notification
{
	MIKMIDIEndpoint *unpluggedEndpoint = [notification userInfo][MIKMIDIEndpointKey];
	MIKMIDIDevice *unpluggedDevice = [self deviceContainingEndpoint:unpluggedEndpoint];
	if (unpluggedDevice) [self disconnectFromDevice:unpluggedDevice];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context
{
	if (context != MIKMIDIConnectionManagerKVOContext) {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
		return;
	}
	
	if (object != self.deviceManager) return;
	
	if ([keyPath isEqualToString:@"availableDevices"]) {
		[self updateAvailableDevices];
	}
	
	if (self.includesVirtualDevices &&
		([keyPath isEqualToString:@"virtualSources"] || [keyPath isEqualToString:@"virtualDestinations"])) {
		[self updateAvailableDevices];
	}
}

#pragma mark - Properties

- (MIKMIDIDeviceManager *)deviceManager { return [MIKMIDIDeviceManager sharedDeviceManager]; }

- (MIKMIDIEventHandlerBlock)eventHandler
{
	return _eventHandler ?: ^(MIKMIDISourceEndpoint *s, NSArray *c){};
}

- (void)setIncludesVirtualDevices:(BOOL)includesVirtualDevices
{
	if (includesVirtualDevices != _includesVirtualDevices) {
		_includesVirtualDevices = includesVirtualDevices;
		[self updateAvailableDevices];
	}
}

- (MIKSetOf(MIKMIDIDevice *) *)connectedDevices
{
	return [self.internalConnectedDevices copy];
}

@end
