public enum AudioRouteChangePolicy {
  public static func shouldStop(accepting:Bool,stopRequested:Bool,engineRunning:Bool,
                               deviceChanged:Bool,formatChanged:Bool) -> Bool {
    accepting && !stopRequested && (!engineRunning || deviceChanged || formatChanged)
  }
}
