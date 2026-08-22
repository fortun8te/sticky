using Microsoft.Win32;

namespace StickyWin;

public static class SystemEventsPower
{
    private static Action? _wake;

    public static event Action? Wake
    {
        add
        {
            bool wasEmpty = _wake == null;
            _wake += value;
            if (wasEmpty) SystemEvents.PowerModeChanged += Handle;
        }
        remove
        {
            _wake -= value;
            if (_wake == null) SystemEvents.PowerModeChanged -= Handle;
        }
    }

    private static void Handle(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume) _wake?.Invoke();
    }
}
