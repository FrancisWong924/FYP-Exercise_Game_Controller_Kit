using System.Collections.Generic;
using UnityEngine;

namespace Fyp.ExerSyncKit
{
    /// <summary>
    /// Drains WebSocket text lines on the Unity main thread. Auto-created when a <see cref="ExerSyncKit"/> registers.
    /// </summary>
    [DefaultExecutionOrder(-32000)]
    public sealed class ExerSyncKitMainThreadPump : MonoBehaviour
    {
        static ExerSyncKitMainThreadPump _instance;
        static readonly object Gate = new object();
        readonly List<ExerSyncKit> _inputs = new List<ExerSyncKit>();

        internal static void Register(ExerSyncKit input)
        {
            if (input == null) return;
            lock (Gate)
            {
                EnsureInstance();
                if (!_instance._inputs.Contains(input))
                    _instance._inputs.Add(input);
            }
        }

        internal static void Unregister(ExerSyncKit input)
        {
            if (input == null) return;
            lock (Gate)
            {
                if (_instance == null) return;
                _instance._inputs.Remove(input);
            }
        }

        static void EnsureInstance()
        {
            if (_instance != null) return;
            var go = new GameObject("ExerSyncKitMainThreadPump");
            DontDestroyOnLoad(go);
            _instance = go.AddComponent<ExerSyncKitMainThreadPump>();
        }

        void Update()
        {
            ExerSyncKit[] snap;
            lock (Gate)
            {
                snap = _inputs.Count == 0 ? System.Array.Empty<ExerSyncKit>() : _inputs.ToArray();
            }

            for (var i = 0; i < snap.Length; i++)
                snap[i].ProcessPendingLines();
        }
    }
}
