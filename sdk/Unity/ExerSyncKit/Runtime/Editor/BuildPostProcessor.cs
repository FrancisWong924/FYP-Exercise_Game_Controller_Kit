#if UNITY_EDITOR
using System.IO;
using UnityEditor;
using UnityEditor.Callbacks;
using UnityEngine;

public static class BuildPostProcessor
{
    [PostProcessBuild]
    public static void OnPostprocessBuild(BuildTarget target, string pathToBuiltProject)
    {
        // Only run this automation if building for Windows Standalone targets
        if (target == BuildTarget.StandaloneWindows || target == BuildTarget.StandaloneWindows64)
        {
            // Find where the built game .exe folder is located
            string buildDirectory = Path.GetDirectoryName(pathToBuiltProject);
            
            // Define the source directory containing the server and all its DLL dependencies
            string sourceDirectory = Path.Combine(Application.dataPath, "ExerSyncKit", "Server", "Windows");

            if (Directory.Exists(sourceDirectory))
            {
                // Get all files inside the folder (exe, dlls, pdbs)
                string[] files = Directory.GetFiles(sourceDirectory);

                foreach (string file in files)
                {
                    // Skip Unity meta files so we don't pollute the build folder
                    if (Path.GetExtension(file) == ".meta") continue;

                    string fileName = Path.GetFileName(file);
                    string targetFilePath = Path.Combine(buildDirectory, fileName);

                    try
                    {
                        File.Copy(file, targetFilePath, true);
                        Debug.Log($"[ExerSyncKit Build Pipeline] Successfully copied {fileName} to build directory.");
                    }
                    catch (System.Exception ex)
                    {
                        Debug.LogError($"[ExerSyncKit Build Pipeline] Failed to copy {fileName}. Error: {ex.Message}");
                    }
                }
                Debug.Log("[ExerSyncKit Build Pipeline] All server environment files processed successfully!");
            }
            else
            {
                Debug.LogError($"[ExerSyncKit Build Pipeline] Source directory not found at: {sourceDirectory}");
            }
        }
    }
}
#endif