/*
 * Copyright 2010, 2011 Jonathan Bullard
 *
 *  This file is part of Tunnelblick.
 *
 *  Tunnelblick is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License version 2
 *  as published by the Free Software Foundation.
 *
 *  Tunnelblick is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program (see the file COPYING included with this
 *  distribution); if not, write to the Free Software Foundation, Inc.,
 *  59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *  or see http://www.gnu.org/licenses/.
 */

#import "defines.h"
#import "LogDisplay.h"
#import "MenuController.h"
#import "NSFileManager+TB.h"
#import "LogWindowController.h"

extern NSFileManager        * gFileMgr;

@interface LogDisplay() // PRIVATE METHODS

-(void)         appendLine:             (NSString *)            line
            fromOpenvpnLog:             (BOOL)                  isFromOpenvpnLog;

-(void)         insertLine:             (NSString *)            line
  beforeTunnelblickEntries:             (BOOL)                  beforeTunnelblickEntries
      beforeOpenVPNEntries:             (BOOL)                  beforeOpenVPNEntries
            fromOpenVPNLog:             (BOOL)                  fromOpenVPNLog;

-(void)         didAddLineToLogDisplay;

-(NSString *)   contentsOfPath:         (NSString *)            logPath
                   usePosition:         (unsigned long long *)  logPosition;

-(NSString *)   convertDate:            (NSString *)            line;

-(NSString *)   constructOpenvpnLogPath;
-(NSString *)   constructScriptLogPath;
    
-(NSRange)      rangeOfLineBeforeLineThatStartsAt: (long)       lineStartIndex
                                         inString: (NSString *) text;

-(void)         loadLogs:               (BOOL)                  skipToStartOfLineInOpenvpnLog;

-(void)         logChangedAtPath:       (NSString *)            logPath
                     usePosition:       (unsigned long long *)  logPositionPtr
                  fromOpenvpnLog:       (BOOL)                  isFromOpenvpnLog;

-(void)         openvpnLogChanged;
-(void)         scriptLogChanged;

-(NSString *)   nextLineInTunnelblickString: (NSString * *)     stringPtr
                               fromPosition: (unsigned *)       positionPtr;

-(NSString *)   nextLineInScriptString: (NSString * *)          stringPtr
                    fromPosition:       (unsigned *)            positionPtr;

-(NSString *)   nextLinesInOpenVPNString:(NSString * *)         stringPtr
                    fromPosition:       (unsigned *)            positionPtr;

-(void)         watcher:                (UKKQueue *)            kq
   receivedNotification:                (NSString *)            nm
                forPath:                (NSString *)            fpath;

// Getters and Setters:
-(NSString *)   configurationPath;
-(NSString *)   lastOpenvpnEntryTime;
-(NSString *)   lastScriptEntryTime;
-(NSString *)   openvpnLogPath;
-(NSString *)   scriptLogPath;
-(void)         setLastEntryTime:       (NSString *)            newValue;
-(void)         setLastOpenvpnEntryTime:(NSString *)            newValue;
-(void)         setLastScriptEntryTime: (NSString *)            newValue;
-(void)         setOpenvpnLogPath:      (NSString *)            newValue;
-(void)         setScriptLogPath:       (NSString *)            newValue;

@end

@implementation LogDisplay

-(LogDisplay *) initWithConfigurationPath: (NSString *) inConfigPath;
{
	if (  self = [super init]  ) {
        
        configurationPath = [inConfigPath copy];
        openvpnLogPath = nil;
        scriptLogPath = nil;

        monitorQueue = nil;
        
        lastEntryTime        = @"0000-00-00 00:00:00";
        lastOpenvpnEntryTime = @"0000-00-00 00:00:00";
        lastScriptEntryTime  = @"0000-00-00 00:00:00";
        
        openvpnLogPosition = 0;
        scriptLogPosition  = 0;
        
        logStorage = [[NSTextStorage alloc] init];
        [self clear];
    }
    
    return self;
}

-(void) dealloc
{
    [monitorQueue release];
	[configurationPath release];
    [openvpnLogPath release];
    [scriptLogPath release];
	[logStorage release];
    [lastOpenvpnEntryTime release];
    [lastScriptEntryTime release];
    [super dealloc];
}

// Inserts the current date/time, a message, and a \n to the log display.
-(void)addToLog: (NSString *) text
{
    NSCalendarDate * date = [NSCalendarDate date];
    NSString * dateText = [NSString stringWithFormat:@"%@ %@\n",[date descriptionWithCalendarFormat:@"%Y-%m-%d %H:%M:%S"], text];

	[self insertLine: dateText beforeTunnelblickEntries: NO beforeOpenVPNEntries: NO fromOpenVPNLog: NO];
}

// Clears the log display, displaying only the header line
-(void) clear
{
    [logStorage deleteCharactersInRange: NSMakeRange(0, [logStorage length])];
    [self addToLog: [[NSApp delegate] openVPNLogHeader]];
    
    // Pretend that the line we just displayed came from OpenVPN so we will insert _after_ it
    [self setLastOpenvpnEntryTime: [self lastScriptEntryTime]];
    [self setLastScriptEntryTime: nil];
}

// Starts (or restarts) monitoring newly-created log files.
-(void) startMonitoringLogFiles
{
    [monitorQueue release];
    monitorQueue = [[UKKQueue alloc] init];
    
    [monitorQueue setDelegate: self];
    [monitorQueue setAlwaysNotify: YES];
    
    [self setOpenvpnLogPath: [self constructOpenvpnLogPath]];
    [self setScriptLogPath:  [self constructScriptLogPath]];
    
    // The script log is usually pretty short, so we scan all of it
    scriptLogPosition = 0;
    
    // The OpenVPN log may be huge (verb level 9 can generates several megabyte per second)
    //  so we only scan the last part -- only the last MAX_LOG_DISPLAY_SIZE bytes
    NSDictionary * attributes = [gFileMgr tbFileAttributesAtPath: [self openvpnLogPath] traverseLink: NO];
    NSNumber * fileSizeAsNumber;
    unsigned long long fileSize;
    if (  fileSizeAsNumber = [attributes objectForKey:NSFileSize]  ) {
        fileSize = [fileSizeAsNumber unsignedLongLongValue];
    } else {
        fileSize = 0;
    }
    
    BOOL skipToStartOfLineInOpenvpnLog = FALSE;
    NSUInteger amountToExamine = MAX_LOG_DISPLAY_SIZE;
    if (  fileSize > amountToExamine  ) {
        openvpnLogPosition = fileSize - amountToExamine;
        skipToStartOfLineInOpenvpnLog = TRUE;
    } else {
        openvpnLogPosition = 0;
    }
    
    [self loadLogs: skipToStartOfLineInOpenvpnLog];
    
    [monitorQueue addPathToQueue: [self openvpnLogPath]];
    [monitorQueue addPathToQueue: [self scriptLogPath]];
}

// Stops) monitoring newly-created log files.
-(void) stopMonitoringLogFiles
{
    [monitorQueue release];
    monitorQueue = nil;
}

// Does the initial load of the logs, inserting entries from them in the "correct" chronological order.
// The "correct" order is that all OpenVPN log entries for a particular date/time come before
// any script log entries for that same time.
// Since the log files are in chronological order, we can and do append to (rather than insert into) the log display,
// which is much less processing intensive.
-(void) loadLogs: (BOOL) skipToStartOfLineInOpenvpnLog
{
    [[[NSApp delegate] logScreen] indicateWaiting];
    
    // Save, then clear, the current contents of the log, which consists of messages from Tunnelblick (as opposed to
    // messages from the script log or OpenVPN log)
    NSString * tunnelblickString = [[logStorage string] copy];
    [logStorage deleteCharactersInRange: NSMakeRange(0, [logStorage length])];
    
    NSString * openvpnString = [self contentsOfPath: [self openvpnLogPath] usePosition: &openvpnLogPosition];
    NSString * scriptString  = [self contentsOfPath: [self scriptLogPath]  usePosition: &scriptLogPosition];
    
    unsigned tunnelblickStringPosition = 0;
    unsigned openvpnStringPosition     = 0;
    unsigned scriptStringPosition      = 0;
    
    if (  skipToStartOfLineInOpenvpnLog  ) {
        NSRange r = [openvpnString rangeOfCharacterFromSet: [NSCharacterSet newlineCharacterSet]];
        if (  r.length != 0  ) {
            openvpnStringPosition = r.location + 1;
        }
    }
    
    NSString * tLine = [self nextLineInTunnelblickString: &tunnelblickString fromPosition: &tunnelblickStringPosition];
    NSString * oLine = [self nextLinesInOpenVPNString:    &openvpnString     fromPosition: &openvpnStringPosition    ];
    NSString * sLine = [self nextLineInScriptString:      &scriptString      fromPosition: &scriptStringPosition     ];
    
    NSString * tLineDateTime = @"0000-00-00 00:00:00";
    NSString * oLineDateTime = @"0000-00-00 00:00:00";
    NSString * sLineDateTime = @"0000-00-00 00:00:00";
    
    while (   (tLine != nil)
           || (oLine != nil)
           || (sLine != nil)  ) {
        
        if (  tLine  ) {
            if (  ! [tLine hasPrefix: @" "]  ) {
                tLineDateTime = [tLine substringToIndex: 19];
            }            
        }
        if (  oLine  ) {
            if (  ! [oLine hasPrefix: @" "]  ) {
                oLineDateTime = [oLine substringToIndex: 19];
            }            
        }
        if (  sLine  ) {
            if (  ! [sLine hasPrefix: @" "]  ) {
                sLineDateTime = [sLine substringToIndex: 19];
            }            
        }
        
        if (  tLine  ) {
            if (  oLine  ) {
                if (  sLine  ) {
                    // Have tLine, oLine, and sLine
                    if (  [tLineDateTime compare: oLineDateTime] != NSOrderedDescending ) {
                        if (  [tLineDateTime compare: sLineDateTime] != NSOrderedDescending ) {
                            [self appendLine: tLine fromOpenvpnLog: NO];
                            tLine = [self nextLineInTunnelblickString: &tunnelblickString
                                                         fromPosition: &tunnelblickStringPosition];
                        } else {
                            [self appendLine: sLine fromOpenvpnLog: NO];
                            sLine = [self nextLineInScriptString: &scriptString
                                                    fromPosition: &scriptStringPosition];
                        }
                    } else {
                        if (  [oLineDateTime compare: sLineDateTime] != NSOrderedDescending ) {
                            [self appendLine: oLine fromOpenvpnLog: YES];
                            oLine = [self nextLinesInOpenVPNString: &openvpnString
                                                      fromPosition: &openvpnStringPosition];
                        } else {
                            [self appendLine: sLine fromOpenvpnLog: NO];
                            sLine = [self nextLineInScriptString: &scriptString
                                                    fromPosition: &scriptStringPosition];
                        }
                    }
                } else {
                    // Have tLine and oLine but not sLine
                    if (  [tLineDateTime compare: oLineDateTime] != NSOrderedDescending ) {
                        [self appendLine: tLine fromOpenvpnLog: NO];
                        tLine = [self nextLineInTunnelblickString: &tunnelblickString
                                                     fromPosition: &tunnelblickStringPosition];
                    } else {
                        [self appendLine: oLine fromOpenvpnLog: YES];
                        oLine = [self nextLinesInOpenVPNString: &openvpnString
                                                  fromPosition: &openvpnStringPosition];
                    }
                }
            } else {
                // Have tLine, don't have oLine
                if (  sLine  ) {
                    // Have tLine and sLine but not oLine
                    if (  [tLineDateTime compare: sLineDateTime] != NSOrderedDescending ) {
                        [self appendLine: tLine fromOpenvpnLog: NO];
                        tLine = [self nextLineInTunnelblickString: &tunnelblickString
                                                     fromPosition: &tunnelblickStringPosition];
                    } else {
                        [self appendLine: sLine fromOpenvpnLog: NO];
                        sLine = [self nextLineInScriptString: &scriptString
                                                fromPosition: &scriptStringPosition];
                    }
                } else {
                    // Only have tLine
                    [self appendLine: tLine fromOpenvpnLog: NO];
                    tLine = [self nextLineInTunnelblickString: &tunnelblickString
                                                 fromPosition: &tunnelblickStringPosition];
                }
            }
        } else {
            // Don't have tLine
            if (  oLine  ) {
                if (  sLine  ) {
                    // Have oLine and sLine but not tLine
                    if (  [oLineDateTime compare: sLineDateTime] != NSOrderedDescending ) {
                        [self appendLine: oLine fromOpenvpnLog: YES];
                        oLine = [self nextLinesInOpenVPNString: &openvpnString
                                                  fromPosition: &openvpnStringPosition];
                    } else {
                        [self appendLine: sLine fromOpenvpnLog: NO];
                        sLine = [self nextLineInScriptString: &scriptString
                                                fromPosition: &scriptStringPosition];
                    }
                } else {
                    // Only have oLine
                    [self appendLine: oLine fromOpenvpnLog: YES];
                    oLine = [self nextLinesInOpenVPNString: &openvpnString
                                              fromPosition: &openvpnStringPosition];
                }
            } else {
                // Only have sLine
                if (  sLine  ) {
                    [self appendLine: sLine fromOpenvpnLog: NO];
                    sLine = [self nextLineInScriptString: &scriptString
                                            fromPosition: &scriptStringPosition];
                }
            }
        }
    }
    
    if (  skipToStartOfLineInOpenvpnLog  ) {
        NSString * replacementLine = [NSString stringWithFormat: @"0000-00-00 00:00:00 *Tunnelblick: Some entries have been removed because the log is too long\n"];
        [self insertLine: replacementLine beforeTunnelblickEntries: YES beforeOpenVPNEntries: YES fromOpenVPNLog: NO];
    }
    
    [tunnelblickString release];
    
    [[[NSApp delegate] logScreen] indicateNotWaiting];
}

-(NSString *) contentsOfPath: (NSString *) logPath usePosition: (unsigned long long *) logPosition
{
    // Open file, seek to current position, read to end of file, note new current position, close file
    NSFileHandle * file;
    if (  ! (file = [NSFileHandle fileHandleForReadingAtPath: logPath])  ) {
        NSLog(@"contentsOfPath: no such log file: %@", logPath);
        *logPosition = -1;
        return @"";
    }
    
    [file seekToFileOffset: *logPosition];
    NSData * data = [file readDataToEndOfFile];
    *logPosition = [file offsetInFile];
    [file closeFile];
    
    NSString * scriptLogContents = [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];
    return scriptLogContents;
}

// Returns the next line from the string of a tunnelblick log
// A \n is appended to the line if it doesn't end in one
// If the at the end of the string, nil is returned
-(NSString *) nextLineInTunnelblickString: (NSString * *) stringPtr fromPosition: (unsigned *) positionPtr
{
    NSString * line;
    unsigned stringLength = [*stringPtr length];
    NSRange stringRng = NSMakeRange(*positionPtr, stringLength - *positionPtr);
    NSRange lfRng = [*stringPtr rangeOfString: @"\n" options: 0 range: stringRng];
    if ( lfRng.location == NSNotFound) {
        if (  [*stringPtr length] != *positionPtr  ) {
            line = [*stringPtr substringWithRange: stringRng];
            line = [line stringByAppendingString: @"\n"];
            *positionPtr = stringLength;
        } else {
            return nil;
        }
    } else {
        NSRange lineRng = NSMakeRange(*positionPtr, lfRng.location + 1 - *positionPtr);
        line = [*stringPtr substringWithRange: lineRng];
        *positionPtr += lineRng.length;
    }
    
    return line;
}

// Returns the next line from the string of a script log
// The date/time in the line (if any) is converted to "YYYY-MM-DD HH:MM:SS" form
// A \n is appended to the line if it doesn't end in one
// If the line is not from the OpenVPN log, and the 1st character after the date/time is not a "*", one is inserted
// If the at the end of the string, nil is returned
-(NSString *) nextLineInScriptString: (NSString * *) stringPtr fromPosition: (unsigned *) positionPtr
{
    NSString * line;
    unsigned stringLength = [*stringPtr length];
    NSRange stringRng = NSMakeRange(*positionPtr, stringLength - *positionPtr);
    NSRange lfRng = [*stringPtr rangeOfString: @"\n" options: 0 range: stringRng];
    if ( lfRng.location == NSNotFound) {
        if (  [*stringPtr length] != *positionPtr  ) {
            line = [*stringPtr substringWithRange: stringRng];
            line = [line stringByAppendingString: @"\n"];
            *positionPtr = stringLength;
        } else {
            return nil;
        }
    } else {
        NSRange lineRng = NSMakeRange(*positionPtr, lfRng.location + 1 - *positionPtr);
        line = [*stringPtr substringWithRange: lineRng];
        *positionPtr += lineRng.length;
    }
    
    NSMutableString * newValue = [[[self convertDate: line] mutableCopy] autorelease];
    if (  [newValue length] > 19  ) {
        if (  [[newValue substringWithRange: NSMakeRange(18, 1)] isEqualToString: @" "]  ) {        // (Last digit of seconds)
            if (  ! [[newValue substringWithRange: NSMakeRange(20, 1)] isEqualToString: @"*"]  ) {
                [newValue insertString: @"*" atIndex: 20]; 
            }
        }
    }
    
    return [[newValue copy] autorelease];
}

// Returns the next lines from the string of an OpenVPN log that all have the same date/time
// The date/time in the line (if any) is converted to "YYYY-MM-DD HH:MM:SS" form
// A \n is appended to the lines if it doesn't end in one
// If at the end of the string, nil is returned
-(NSString *) nextLinesInOpenVPNString: (NSString * *) stringPtr fromPosition: (unsigned *) positionPtr
{
    NSMutableString * linesToReturn = [NSMutableString stringWithCapacity: 2000];
    unsigned lengthOfLinesUsed = 0;
    
    NSRange substringRng = NSMakeRange(*positionPtr, [*stringPtr length] - *positionPtr);
    
    NSString * originalLine;
    NSString * line;
    NSRange lfRng;
    BOOL firstLine = TRUE;
    NSString * dateTimeToAccept = nil;
    while (  NSNotFound != (lfRng = [*stringPtr rangeOfString: @"\n" options: 0 range: substringRng]).location  ) {
        
        if (  lfRng.location == substringRng.location  ) {
            lengthOfLinesUsed++;        // Just ignore empty lines
            substringRng.location++;
            substringRng.length--;
        } else {
            originalLine = [*stringPtr substringWithRange: NSMakeRange(substringRng.location, lfRng.location - substringRng.location + 1)];
            line = [self convertDate: originalLine];                // Not the length of this new, converted line
            BOOL hasDateTime = ! [[line substringWithRange: NSMakeRange(0, 1)] isEqualToString: @" "];
            
            if (  firstLine) {
                if (  hasDateTime  ) {
                    dateTimeToAccept = [line substringWithRange: NSMakeRange(0, 19)];
                }
                
            } else {
                if (  dateTimeToAccept  ) {
                    if (  ! [dateTimeToAccept isEqualToString: [line substringWithRange: NSMakeRange(0, 19)]]  ) {
                        break;
                    }
                } else {
                    if (  hasDateTime  ) {
                        break;
                    }
                }
            }
            
            firstLine = FALSE;
            
            [linesToReturn appendString: line];
            
            unsigned originalLineLength = [originalLine length];
            lengthOfLinesUsed     += originalLineLength;
            substringRng.location += originalLineLength;
            substringRng.length   -= originalLineLength;
        }
    }
    
    unsigned lengthOfLines = [linesToReturn length];
    
    if (  lengthOfLines == 0  ) {
        return nil;
    }
    
    *positionPtr += lengthOfLinesUsed;
    
    return linesToReturn;
}

// If a line starts with the date/time as "Day dd Mon HH:MM:SS YYYY", converts it to start with "YYYY-MM-DD HH:MM:SS "
// Otherwise the line is indented
-(NSString *) convertDate: (NSString *) line
{
    NSString * lineToReturn;
    // Convert date/time to YYYY-MM-DD HH:MM:SS
    const char * cLogLine;
    const char * cRestOfLogLine;
    struct tm cTime;
    char cDateTimeStringBuffer[] = "1234567890123456789012345678901";
    cLogLine = [line UTF8String];
    cRestOfLogLine = strptime(cLogLine, "%c", &cTime);
    if (  cRestOfLogLine  ) {
        size_t timeLen = strftime(cDateTimeStringBuffer, 30, "%Y-%m-%d %H:%M:%S", &cTime);
        if (  timeLen  ) {
            lineToReturn = [NSString stringWithFormat: @"%s%s", cDateTimeStringBuffer, cRestOfLogLine];
        } else {
            lineToReturn = [NSString stringWithFormat: @"                                        %@", line];
        }
    } else {
        lineToReturn = [NSString stringWithFormat: @"                                        %@", line];
    }
    
    return lineToReturn;
}

// Appends a line to the log display
-(void) appendLine: (NSString *) line fromOpenvpnLog: (BOOL) isFromOpenvpnLog
{
    NSAttributedString * msgAS = [[[NSAttributedString alloc] initWithString: line] autorelease];
    [logStorage appendAttributedString: msgAS];
    
    if (  [line length] > 18 ) {
        if (  ! [[line substringWithRange: NSMakeRange(0, 1)] isEqualToString: @"\n"]  ) {
            if (  isFromOpenvpnLog  ) {
                [self setLastOpenvpnEntryTime: [line substringWithRange: NSMakeRange(0, 19)]];
            } else {
                [self setLastScriptEntryTime:  [line substringWithRange: NSMakeRange(0, 19)]];
            }
        }
    }

    [self didAddLineToLogDisplay];
}

// We added a line to the log display -- if already displaying the maximum number of lines then remove some lines (i.e. scroll off the top)
-(void) didAddLineToLogDisplay
{
    NSUInteger currentLength = [logStorage length];
    if (  currentLength > MAX_LOG_DISPLAY_SIZE  ) {
        // Remove 10% of the contents of the display
        NSUInteger charsToRemove = currentLength / 10;
        if (  charsToRemove < 1000  ) {
            charsToRemove = 1000;
        }
        // Find first LF after that, and remove up to and including that LF
        NSString * text = [logStorage string];
        NSRange rLf = [text rangeOfString: @"\n" options: 0 range: NSMakeRange(charsToRemove, [text length] - charsToRemove)];
        if (  NSNotFound == rLf.location  ) {
            // Or first LF before that
            rLf = [text rangeOfString: @"\n" options: NSBackwardsSearch range: NSMakeRange(charsToRemove, [text length] - charsToRemove)];
            if (  NSNotFound == rLf.location  ) {
                // Or just remove that number of characters
                rLf.location = charsToRemove;
            }
        }
        
        NSString * replacementLine = [NSString stringWithFormat: @"0000-00-00 00:00:00 *Tunnelblick: Some entries have been removed because the log is too long\n"];
        [logStorage replaceCharactersInRange: NSMakeRange(0, rLf.location +1) withString: replacementLine];
    }
}

// Invoked when either log file has changed.
-(void) watcher: (UKKQueue *) kq receivedNotification: (NSString *) nm forPath: (NSString *) fpath
{
    // Do some primitive throttling -- only queue three requests per second
    long rightNow = floor([NSDate timeIntervalSinceReferenceDate]);
    if (  rightNow == secondWeLastQueuedAChange  ) {
        numberOfRequestsInThatSecond++;
        if (  numberOfRequestsInThatSecond > 3) {
            if (  ! watchdogTimer  ) {
                // Set a timer to queue a request later. (This will happen at most once per second.)
                watchdogTimer = [NSTimer scheduledTimerWithTimeInterval: (NSTimeInterval) 1.0
                                                                 target: self
                                                               selector: @selector(watchdogTimedOutHandler:)
                                                               userInfo: fpath
                                                                repeats: NO];
            }
            return;
        }
    } else {
        secondWeLastQueuedAChange    = rightNow;
        numberOfRequestsInThatSecond = 0;
    }

    if (  monitorQueue  ) {
        if (  [[[fpath stringByDeletingPathExtension] pathExtension] isEqualToString: @"openvpn"]  ) {
            [self performSelectorOnMainThread: @selector(openvpnLogChanged) withObject: nil waitUntilDone: YES];
        } else {
            [self performSelectorOnMainThread: @selector(scriptLogChanged) withObject: nil waitUntilDone: YES];
        }
    }
}

-(void) watchdogTimedOutHandler: (NSTimer *) timer
{
    watchdogTimer = nil;
    
    NSString * fpath = [timer userInfo];
    
    if (  monitorQueue  ) {
        if (  [[[fpath stringByDeletingPathExtension] pathExtension] isEqualToString: @"openvpn"]  ) {
            [self performSelectorOnMainThread: @selector(openvpnLogChanged) withObject: nil waitUntilDone: YES];
        } else {
            [self performSelectorOnMainThread: @selector(scriptLogChanged) withObject: nil waitUntilDone: YES];
        }
    }
    
}

-(void) openvpnLogChanged
{
    [self logChangedAtPath: [self openvpnLogPath] usePosition: &openvpnLogPosition fromOpenvpnLog: YES];
}

-(void) scriptLogChanged
{
    [self logChangedAtPath: [self scriptLogPath] usePosition: &scriptLogPosition fromOpenvpnLog: NO];
}

-(void) logChangedAtPath: (NSString *) logPath usePosition: (unsigned long long *) logPositionPtr fromOpenvpnLog: (BOOL) isFromOpenvpnLog
{
    // Return without doing anything if an error has occurred
    if (  *logPositionPtr == -1  ) {
        return;
    }
    
    // Return without doing anything if log file doesn't exist
    if (  ! [gFileMgr fileExistsAtPath: logPath]  ) {
        return;
    }
    
    // Go through the log file contents one line at a time
    NSString * logString = [self contentsOfPath: logPath  usePosition: logPositionPtr];
    unsigned logStringPosition = 0;
    
    NSString * line;
    if (  isFromOpenvpnLog  ) {
        line = [self nextLinesInOpenVPNString: &logString fromPosition:  &logStringPosition];
    } else {
        line = [self nextLineInScriptString:   &logString fromPosition:  &logStringPosition];
    }
    
    while ( line ) {
        [self insertLine: line beforeTunnelblickEntries: isFromOpenvpnLog beforeOpenVPNEntries: NO fromOpenVPNLog: isFromOpenvpnLog];
        if (  isFromOpenvpnLog  ) {
            line = [self nextLinesInOpenVPNString: &logString fromPosition:  &logStringPosition];
        } else {
            line = [self nextLineInScriptString:   &logString fromPosition:  &logStringPosition];
        }
    }
}

// Inserts a line into the log display at the "correct" position
// The "correct" order is that all OpenVPN log entries for a particular date/time come before
// any script log entries for that same time.
-(void) insertLine: (NSString *) line beforeTunnelblickEntries: (BOOL) beforeTunnelblickEntries  beforeOpenVPNEntries: (BOOL) beforeOpenVPNEntries fromOpenVPNLog: (BOOL) fromOpenVPNLog
{
    NSString * text = nil;

    NSAttributedString * msgAS = [[[NSAttributedString alloc] initWithString: line] autorelease];

    if (  ! text  ) {
        text = [logStorage string];
    }
    
    NSString * lineTime;
    if (   [line length] < 19
        || [[line substringWithRange: NSMakeRange(0, 1)] isEqualToString: @" "]  ) {
        if (  fromOpenVPNLog  ) {
            lineTime = [self lastOpenvpnEntryTime];
        } else {
            lineTime = [self lastScriptEntryTime];
        }
    } else {
        lineTime = [line substringWithRange: NSMakeRange(0, 19)];
        if (  fromOpenVPNLog  ) {
            [self setLastOpenvpnEntryTime: lineTime];
        } else {
            [self setLastScriptEntryTime:  lineTime];
        }
    }

    NSRange textRng = NSMakeRange(0, [text length]);
    
    // Special case: Nothing in log. Just append to it.
    if (  textRng.length == 0  ) {
        [logStorage appendAttributedString: msgAS];
        [self setLastEntryTime: lineTime];
        [self didAddLineToLogDisplay];
        return;
    }
    
    // Special case: time is the same or greater than last entry in the log. Just append to it.
    NSComparisonResult result = [lastEntryTime compare: lineTime];
    if (  result != NSOrderedDescending  ) {
        [logStorage appendAttributedString: msgAS];
        [self setLastEntryTime: lineTime];
        [self didAddLineToLogDisplay];
        return;
    }
    
    // Search backwards through the display
    NSRange currentLineRng = [self rangeOfLineBeforeLineThatStartsAt: textRng.length inString: text];
    unsigned numberOfLinesSkippedBackward = 0;

    while (  currentLineRng.length != 0  ) {
        NSComparisonResult result = [lineTime compare: [text substringWithRange: NSMakeRange(currentLineRng.location, 19)]];
        
        if (  result == NSOrderedDescending  ) {
            [logStorage insertAttributedString: msgAS atIndex: currentLineRng.location + currentLineRng.length];
            [self didAddLineToLogDisplay];
            return;
        }
        
        if (   (result == NSOrderedSame)
            && ( ! (beforeTunnelblickEntries && beforeOpenVPNEntries) )  ) {
            BOOL currentFromOpenVPN = TRUE;
            if ( currentLineRng.length > 20  ) {
                currentFromOpenVPN = ! [[text substringWithRange: NSMakeRange(currentLineRng.location+20, 1)] isEqualToString: @"*"];
            }
            if (  ! (beforeTunnelblickEntries ^ currentFromOpenVPN)  ) {
                if (  numberOfLinesSkippedBackward == 0  ) {
                    [logStorage appendAttributedString: msgAS];
                    [self setLastEntryTime: lineTime];
                    [self didAddLineToLogDisplay];
                    return;
                } else {
                    [logStorage insertAttributedString: msgAS atIndex: currentLineRng.location + currentLineRng.length];
                    [self didAddLineToLogDisplay];
                    return;
                }
            }
            if (  ! beforeTunnelblickEntries  ) {
                if (  numberOfLinesSkippedBackward == 0  ) {
                    [logStorage appendAttributedString: msgAS];
                    [self setLastEntryTime: lineTime];
                    [self didAddLineToLogDisplay];
                    return;
                } else {
                    [logStorage insertAttributedString: msgAS atIndex: currentLineRng.location + currentLineRng.length];
                    [self didAddLineToLogDisplay];
                    return;
                }
            }
        }
        
        currentLineRng = [self rangeOfLineBeforeLineThatStartsAt: currentLineRng.location inString: text];
        numberOfLinesSkippedBackward++;
    }
    
    if (  [logStorage length] == 0  ) {
        [logStorage appendAttributedString: msgAS];
        [self setLastEntryTime: lineTime];
    } else {
        [logStorage insertAttributedString: msgAS atIndex: 0];
    }
    [self didAddLineToLogDisplay];
}

// Returns an NSRange for the previous line
// Considers the "previous line" to include all lines with no date/time
-(NSRange) rangeOfLineBeforeLineThatStartsAt: (long) lineStartIndex inString: (NSString *) text
{
    if (  lineStartIndex == 0  ) {
        return NSMakeRange(NSNotFound, 0);
    }
    
    long justPastEnd = lineStartIndex;
    
    NSRange currentLineRng;
    do {
        NSRange LfRng = [text rangeOfString: @"\n" options: NSBackwardsSearch range: NSMakeRange(0, lineStartIndex - 1)];
        if (  LfRng.length == 0  ) {
            // Only one line in log
            currentLineRng = NSMakeRange(0, justPastEnd);
            return currentLineRng;
        }
        // More than one line in log
        currentLineRng = NSMakeRange(LfRng.location + 1, justPastEnd - LfRng.location - 1);
        lineStartIndex = currentLineRng.location;
    } while (  [[text substringWithRange: NSMakeRange(currentLineRng.location, 1)] isEqualToString: @" "]  );
    
    return currentLineRng;
}

// Returns a path for a script log file
// It is composed of a prefix, the configuration path with "-" replaced by "--" and "/" replaced by "-S", and an extension of ".script.log"
//
// If the configuration file is in the home folder, we pretend it is in /Users/username instead (just for the purpose
// of creating the filename -- we never try to access /Users/username...). We do this because
// the scripts have access to the username, but don't have access to the actual location of the home folder, and the home
// folder may be located in a non-standard location (on a remote volume for example).
-(NSString *) constructScriptLogPath
{
    NSMutableString * logBase;
    if (  [configurationPath hasPrefix: NSHomeDirectory()]  ) {
        logBase = [[[NSString stringWithFormat: @"/Users/%@%@", NSUserName(), [configurationPath substringFromIndex: [NSHomeDirectory() length]]] mutableCopy] autorelease];
    } else {
        logBase = [[[self configurationPath] mutableCopy] autorelease];
    }
    
    if (  [[[self configurationPath] pathExtension] isEqualToString: @"tblk"]) {
        [logBase appendString: @"/Contents/Resources/config.ovpn"];
    }
    
    [logBase replaceOccurrencesOfString: @"-" withString: @"--" options: 0 range: NSMakeRange(0, [logBase length])];
    [logBase replaceOccurrencesOfString: @"/" withString: @"-S" options: 0 range: NSMakeRange(0, [logBase length])];
    NSString * returnVal = [NSString stringWithFormat: @"%@/%@.script.log", LOG_DIR, logBase];
    return returnVal;
}

// Returns a path for an OpenVPN log file.
// It is composed of a prefix, the configuration path with "-" replaced by "--" and "/" replaced by "-S" , and extensions of
//      * an underscore-separated list of the values for useScripts, skipScrSec, cfgLocCode, noMonitor, and bitMask
//      * the port number;
//      * "openvpn"; and
//      * "log"
// So what we actually do is search for a file with the specified encoded configuration path, and return the path to that file.
//
// If the configuration file is in the home folder, we pretend it is in /Users/username instead (just for the purpose
// of creating the filename -- we never try to access /Users/username...). We do this because
// the scripts have access to the username, but don't have access to the actual location of the home folder, and the home
// folder may be located in a non-standard location (on a remote volume for example).
-(NSString *) constructOpenvpnLogPath
{
    NSMutableString * logBase;
    if (  [configurationPath hasPrefix: NSHomeDirectory()]  ) {
        logBase = [[[NSString stringWithFormat: @"/Users/%@%@", NSUserName(), [configurationPath substringFromIndex: [NSHomeDirectory() length]]] mutableCopy] autorelease];
    } else {
        logBase = [[[self configurationPath] mutableCopy] autorelease];
    }
    
    if (  [[logBase pathExtension] isEqualToString: @"tblk"]  ) {
        [logBase appendString: @"/Contents/Resources/config.ovpn"];
    }
    
    [logBase replaceOccurrencesOfString: @"-" withString: @"--" options: 0 range: NSMakeRange(0, [logBase length])];
    [logBase replaceOccurrencesOfString: @"/" withString: @"-S" options: 0 range: NSMakeRange(0, [logBase length])];
    NSString * logPathPrefix = [NSString stringWithFormat: @"%@/%@", LOG_DIR, logBase];

    NSString * filename;
    NSDirectoryEnumerator * dirEnum = [gFileMgr enumeratorAtPath: LOG_DIR];
    while (  filename = [dirEnum nextObject]  ) {
        [dirEnum skipDescendents];
        NSString * oldFullPath = [LOG_DIR stringByAppendingPathComponent: filename];
        if (  [oldFullPath hasPrefix: logPathPrefix]  ) {
            if (   [[filename pathExtension] isEqualToString: @"log"]
                && [[[filename stringByDeletingPathExtension] pathExtension] isEqualToString: @"openvpn"]  ) {
                return [[oldFullPath copy] autorelease];
            }
        }
    }
    NSLog(@"constructOpenvpnLogPath: Cannot find OpenVPN log file for %@", [self configurationPath]);
    return nil;
}

//*********************************************************************************************************
// Getters and Setters:

-(NSString *) configurationPath
{
    return configurationPath;
}

-(NSString *) lastOpenvpnEntryTime
{
    return lastOpenvpnEntryTime;
}

-(NSString *) lastScriptEntryTime
{
    return lastScriptEntryTime;
}

-(NSString *) openvpnLogPath
{
    return openvpnLogPath;
}

-(NSString *) scriptLogPath
{
    return scriptLogPath;
}

-(NSTextStorage *) logStorage
{
    return logStorage;
}

-(void) setLastEntryTime: (NSString *) newValue
{
    [newValue retain];
    [lastEntryTime release];
    lastEntryTime = newValue;
}

-(void) setLastOpenvpnEntryTime: (NSString *) newValue
{
    [newValue retain];
    [lastOpenvpnEntryTime release];
    lastOpenvpnEntryTime = newValue;
}

-(void) setLastScriptEntryTime: (NSString *) newValue
{
    [newValue retain];
    [lastScriptEntryTime release];
    lastScriptEntryTime = newValue;
}

-(void) setOpenvpnLogPath: (NSString *) newValue
{
    [newValue retain];
    [openvpnLogPath release];
    openvpnLogPath = newValue;
}

-(void) setScriptLogPath: (NSString *) newValue
{
    [newValue retain];
    [scriptLogPath release];
    scriptLogPath = newValue;
}

@end
