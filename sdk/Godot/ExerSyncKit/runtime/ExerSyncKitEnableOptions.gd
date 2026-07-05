class_name ExerSyncKitEnableOptions
extends RefCounted

var GameId: String = ""
var Version: int = 1
var LayoutJson: Variant = null
var OnStateChanged: Callable
var OnConnected: Callable
var OnDisconnected: Callable
var OnServerUnavailable: Callable
var OnControllerConnected: Callable
var OnControllerDisconnected: Callable
var OnPause: Callable
var OnResume: Callable
var OnInput: Callable
