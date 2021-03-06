// This file is part of Background Music.
//
// Background Music is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation, either version 2 of the
// License, or (at your option) any later version.
//
// Background Music is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Background Music. If not, see <http://www.gnu.org/licenses/>.

//
//  AppDelegate.mm
//  BGMApp
//
//  Copyright © 2016, 2017 Kyle Neideck
//

// Self Includes
#import "AppDelegate.h"

// Local Includes
#import "BGM_Types.h"
#import "BGMUserDefaults.h"
#import "BGMAudioDeviceManager.h"
#import "BGMMusicPlayers.h"
#import "BGMAutoPauseMusic.h"
#import "BGMAutoPauseMenuItem.h"
#import "BGMAppVolumes.h"
#import "BGMPreferencesMenu.h"
#import "BGMXPCListener.h"
#import "SystemPreferences.h"


#pragma clang assume_nonnull begin

static float const kStatusBarIconPadding = 0.25;

@implementation AppDelegate {
    // The button in the system status bar (the bar with volume, battery, clock, etc.) to show the main menu
    // for the app. These are called "menu bar extras" in the Human Interface Guidelines.
    NSStatusItem* statusBarItem;
    
    // Only show the 'BGMXPCHelper is missing' error dialog once.
    BOOL haveShownXPCHelperErrorMessage;
    
    BGMAutoPauseMusic* autoPauseMusic;
    BGMAutoPauseMenuItem* autoPauseMenuItem;
    BGMMusicPlayers* musicPlayers;
    BGMAppVolumes* appVolumes;
    BGMAudioDeviceManager* audioDevices;
    BGMPreferencesMenu* prefsMenu;
    BGMXPCListener* xpcListener;
}

- (void) awakeFromNib {
    // Show BGMApp in the dock, if the command-line option for that was passed. This is used by the UI tests.
    if ([NSProcessInfo.processInfo.arguments indexOfObject:@"--show-dock-icon"] != NSNotFound) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    }
    
    haveShownXPCHelperErrorMessage = NO;
    
    // Set up the status bar item
    statusBarItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    
    // Set the icon
    NSImage* icon = [NSImage imageNamed:@"FermataIcon"];
    if (icon != nil) {
        CGFloat lengthMinusPadding = [[statusBarItem button] frame].size.height * (1 - kStatusBarIconPadding);
        [icon setSize:NSMakeSize(lengthMinusPadding, lengthMinusPadding)];
        // Make the icon a "template image" so it gets drawn colour-inverted when it's highlighted or the status
        // bar's in dark mode
        [icon setTemplate:YES];
        statusBarItem.button.image = icon;
    } else {
        // If our icon is missing for some reason, fallback to a fermata character (1D110)
        statusBarItem.button.title = @"𝄐";
    }
    
    // Set the main menu
    statusBarItem.menu = self.bgmMenu;
}

- (void) applicationDidFinishLaunching:(NSNotification*)aNotification {
    #pragma unused (aNotification)
    
    // Log the version/build number.
    //
    // TODO: NSLog should only be used for logging errors.
    // TODO: Automatically add the commit ID to the end of the build number for unreleased builds. (In the
    //       Info.plist or something -- not here.)
    NSLog(@"BGMApp version: %@, BGMApp build number: %@",
          NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
          NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]);

    // Set up the rest of the UI and other external interfaces.

    // audioDevices coordinates BGMDevice and the output device. It manages playthrough, volume/mute controls, etc.
    {
        NSError* error;
        audioDevices = [[BGMAudioDeviceManager alloc] initWithError:&error];
        if (audioDevices == nil) {
            [self showDeviceNotFoundErrorMessageAndExit:error.code];
            return;
        }
    }

    {
        NSError* error = [audioDevices setBGMDeviceAsOSDefault];
        if (error) {
            [self showSetDeviceAsDefaultError:error
                                      message:@"Could not set Background Music Device as your default audio device."
                              informativeText:@"You might be able to set it yourself."];
        }
    }

    BGMUserDefaults* userDefaults = [self createUserDefaults];

    musicPlayers = [[BGMMusicPlayers alloc] initWithAudioDevices:audioDevices
                                                    userDefaults:userDefaults];
    
    autoPauseMusic = [[BGMAutoPauseMusic alloc] initWithAudioDevices:audioDevices
                                                        musicPlayers:musicPlayers];
    
    autoPauseMenuItem = [[BGMAutoPauseMenuItem alloc] initWithMenuItem:self.autoPauseMenuItemUnwrapped
                                                        autoPauseMusic:autoPauseMusic
                                                          musicPlayers:musicPlayers
                                                          userDefaults:userDefaults];
    
    xpcListener = [[BGMXPCListener alloc] initWithAudioDevices:audioDevices
                                  helperConnectionErrorHandler:^(NSError* error) {
                                      NSLog(@"AppDelegate::applicationDidFinishLaunching: (helperConnectionErrorHandler) "
                                             "BGMXPCHelper connection error: %@",
                                            error);
                                      
                                      [self showXPCHelperErrorMessage:error];
                                  }];
    
    appVolumes = [[BGMAppVolumes alloc] initWithMenu:self.bgmMenu
                                       appVolumeView:self.appVolumeView
                                        audioDevices:audioDevices];
    
    prefsMenu = [[BGMPreferencesMenu alloc] initWithBGMMenu:self.bgmMenu
                                               audioDevices:audioDevices
                                               musicPlayers:musicPlayers
                                                 aboutPanel:self.aboutPanel
                                      aboutPanelLicenseView:self.aboutPanelLicenseView];
    
    // Handle events about the main menu. (See the NSMenuDelegate methods below.)
    self.bgmMenu.delegate = self;
}

- (BGMUserDefaults*) createUserDefaults {
    BOOL persistentDefaults = [NSProcessInfo.processInfo.arguments indexOfObject:@"--no-persistent-data"] == NSNotFound;
    NSUserDefaults* wrappedDefaults = persistentDefaults ? [NSUserDefaults standardUserDefaults] : nil;
    return [[BGMUserDefaults alloc] initWithDefaults:wrappedDefaults];
}

- (void) applicationWillTerminate:(NSNotification*)aNotification {
    #pragma unused (aNotification)
    
    DebugMsg("AppDelegate::applicationWillTerminate");

    NSError* error = [audioDevices unsetBGMDeviceAsOSDefault];
    
    if (error) {
        [self showSetDeviceAsDefaultError:error
                                  message:@"Failed to reset your system's audio output device."
                          informativeText:@"You'll have to change it yourself to get audio working again."];
    }
}

#pragma mark Error messages

- (void) showDeviceNotFoundErrorMessageAndExit:(NSInteger)code {
    // Show an error dialog and exit if either BGMDevice wasn't found on the system or we couldn't find any output devices
    
    // NSAlert should only be used on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert* alert = [NSAlert new];
        
        if (code == kBGMErrorCode_BGMDeviceNotFound) {
            // TODO: Check whether the driver files are in /Library/Audio/Plug-Ins/HAL and offer to install them if not. Also,
            //       it would be nice if we could restart coreaudiod automatically (using launchd).
            [alert setMessageText:@"Could not find the Background Music virtual audio device."];
            [alert setInformativeText:@"Make sure you've installed Background Music.driver to /Library/Audio/Plug-Ins/HAL and restarted coreaudiod (e.g. \"sudo killall coreaudiod\")."];
        } else if (code == kBGMErrorCode_OutputDeviceNotFound) {
            [alert setMessageText:@"Could not find an audio output device."];
            [alert setInformativeText:@"If you do have one installed, this is probably a bug. Sorry about that. Feel free to file an issue on GitHub."];
        }
        
        [alert runModal];
        [NSApp terminate:self];
    });
}

- (void) showXPCHelperErrorMessage:(NSError*)error {
    if (!haveShownXPCHelperErrorMessage) {
        haveShownXPCHelperErrorMessage = YES;
        
        // NSAlert should only be used on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert* alert = [NSAlert new];
            
            // TODO: Offer to install BGMXPCHelper if it's missing.
            // TODO: Show suppression button?
            [alert setMessageText:@"Error connecting to BGMXPCHelper."];
            [alert setInformativeText:[NSString stringWithFormat:@"%s%s%@ (%lu)",
                                       "Make sure you have BGMXPCHelper installed. There are instructions in the "
                                       "README.md file.\n\n"
                                       "Background Music might still work, but it won't work as well as it could.",
                                       "\n\nDetails:\n",
                                       [error localizedDescription],
                                       [error code]]];
            [alert runModal];
        });
    }
}

- (void) showSetDeviceAsDefaultError:(NSError*)error
                             message:(NSString*)msg
                     informativeText:(NSString*)info {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"%@ %@ Error: %@", msg, info, error);
        
        NSAlert* alert = [NSAlert alertWithError:error];
        alert.messageText = msg;
        alert.informativeText = info;
        
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Open Sound in System Preferences"];
        
        NSModalResponse buttonClicked = [alert runModal];
        
        if (buttonClicked != NSAlertFirstButtonReturn) {  // 'OK' is the first button.
            [self openSysPrefsSoundOutput];
        }
    });
}

- (void) openSysPrefsSoundOutput {
    SystemPreferencesApplication* __nullable sysPrefs =
        [SBApplication applicationWithBundleIdentifier:@"com.apple.systempreferences"];
    
    if (!sysPrefs) {
        NSLog(@"Could not open System Preferences");
        return;
    }
    
    // In System Preferences, go to the "Output" tab on the "Sound" pane.
    for (SystemPreferencesPane* pane : [sysPrefs panes]) {
        DebugMsg("AppDelegate::openSysPrefsSoundOutput: pane = %s", [pane.name UTF8String]);
        
        if ([pane.id isEqualToString:@"com.apple.preference.sound"]) {
            sysPrefs.currentPane = pane;
            
            for (SystemPreferencesAnchor* anchor : [pane anchors]) {
                DebugMsg("AppDelegate::openSysPrefsSoundOutput: anchor = %s", [anchor.name UTF8String]);
                
                if ([[anchor.name lowercaseString] isEqualToString:@"output"]) {
                    DebugMsg("AppDelegate::openSysPrefsSoundOutput: Showing Output in Sound pane.");
                    
                    [anchor reveal];
                }
            }
        }
    }
    
    // Bring System Preferences to the foreground.
    [sysPrefs activate];
}

#pragma mark NSMenuDelegate

- (void) menuNeedsUpdate:(NSMenu*)menu {
    if ([menu isEqual:self.bgmMenu]) {
        [autoPauseMenuItem parentMenuNeedsUpdate];
    } else {
        DebugMsg("AppDelegate::menuNeedsUpdate: Warning: unexpected menu. menu=%s", menu.description.UTF8String);
    }
}

- (void) menu:(NSMenu*)menu willHighlightItem:(NSMenuItem* __nullable)item {
    if ([menu isEqual:self.bgmMenu]) {
        [autoPauseMenuItem parentMenuItemWillHighlight:item];
    } else {
        DebugMsg("AppDelegate::menu: Warning: unexpected menu. menu=%s", menu.description.UTF8String);
    }
}

@end

#pragma clang assume_nonnull end

