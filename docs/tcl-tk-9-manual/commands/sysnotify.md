# tk

*Tk*

## NAME

sysnotify - Creates a notification window with a title and message.

## SYNOPSIS

**tk sysnotify** *title message*

## DESCRIPTION

The **tk sysnotify** command creates a platform-specific system notification alert. Its intent is to provide a brief, unobtrusive notification to the user by popping up a window that briefly appears in a corner of the screen.

## EXAMPLE

Here is an example of the **tk sysnotify** code:

```tcl
tk sysnotify "Alert" \
      "This is just a test of the Tk System Notification Code."
```

## PLATFORM NOTES

The macOS and Windows versions are native implementations using system API's. The X11 version has a conditional dependency on libnotify, and falls back to a Tcl-only implementation if libnotify is not installed. On each platform the notification includes a platform-specific default image to accompany the text.

**macOS**

The macOS version will request permission from the user to authorize notifications. This must be activated in Apple's System Preferences Notifications section.

  If deploying an application using the standalone version of Wish.app, setting the bundle ID in the applications Info.plist file to begin with “**com**” seems necessary for notifications to work. Using a different prefix for the bundle ID, such as something like “**tk.tcl.tkchat**”, will cause notifications to silently fail.

**Windows**

The image is taken from the system tray, i.e., **sysnotify** can only be called when a **systray** was installed.

## KEYWORDS

notify, alert
