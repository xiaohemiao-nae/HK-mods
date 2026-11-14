// BenchWarp —— 空洞骑士 1.5.12620 长椅传送 mod（地图点击版）
//
// 交互规则：
//   · 只有坐在长椅上处于休息状态（PlayerData.atBench）时，地图上才会出现长椅图标；
//   · 点击某张已解锁长椅的图标 → 直接传送到那张长椅；
//   · 没坐在长椅上时，本 mod 完全不动手，地图保持原版行为。
//
// 图标定位原理（与游戏自己的指南针同一套坐标）：
//   游戏的地图层级是  GameMap ─┬─ areaCity   （14 个区域对象）
//                              ├─ areaGreenpath
//                              └─ ...
//   每个区域对象的子对象就是「场景地图块」，其 GameObject 名字正好是场景名
//   （GameMap.SetupMap 里就是拿 transform.name 去比对 PlayerData.scenesMapped）。
//   所以只要按名字找到场景块，取它的 SpriteRenderer 世界位置，投影到屏幕即可，
//   不需要自己维护任何地图坐标表。
//
// 传送原理（复用游戏官方流程，不改游戏文件）：
//   1. PlayerData.SetBenchRespawn(marker, scene, 1, true)  —— 复活点指向目标长椅
//   2. 跨场景：GameManager.ReadyForRespawn(false) → BeginSceneTransition(respawnScene)
//      进场时 GameManager.EnterHero 发现 RespawningHero → 起 HeroController.Respawn()
//   3. 同场景：直接 HeroController.Respawn()
//   最终由 RespawnMarker + "Bench Control" FSM 把角色放成「坐在长椅上」的状态，
//   所以传送后与正常休息完全一致，存档点也自然变成目标长椅。

using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using UnityEngine;
using UnityEngine.SceneManagement;

// csproj 关掉了自动生成的 AssemblyInfo，这里手工声明
[assembly: System.Reflection.AssemblyVersion("1.6.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.6.0.0")]
// 模组身份：Better HK / 作者 小禾苗。写进程序集元数据，资源管理器里能直接看到。
[assembly: System.Reflection.AssemblyTitle("Better HK - Bench Warp")]
[assembly: System.Reflection.AssemblyProduct("Better HK")]
[assembly: System.Reflection.AssemblyCompany("小禾苗")]
[assembly: System.Reflection.AssemblyCopyright("(c) 小禾苗")]

namespace BenchWarpMod
{
    public static class Bootstrap
    {
        public const string ModVersion = "1.6.0";

        private static BenchWarpBehaviour _behaviour;
        private static UnityEngine.Events.UnityAction<
            UnityEngine.SceneManagement.Scene,
            UnityEngine.SceneManagement.LoadSceneMode> _onSceneLoaded;

        public static void Init()
        {
            try
            {
                // 这个 mod 只被 RuntimeInitializeOnLoads 调用一次 Init。
                // 早先版本创建对象后只调了 DontDestroyOnLoad，结果真正加载关卡场景时
                // 整个 behaviour 被销毁 —— 症状就是「进游戏后按 F1 没反应、没有光标、
                // 日志停在菜单那几行」。所以现在双保险：注册 sceneLoaded，每次场景加载都补齐。
                TryHookScenes();
                EnsureBehaviour();
                Log("BenchWarp v" + ModVersion + " loaded (map-click edition)");
            }
            catch (Exception e)
            {
                Log("Bootstrap failed: " + e);
            }
        }

        private static void TryHookScenes()
        {
            try
            {
                if (_onSceneLoaded != null) return;
                _onSceneLoaded = OnSceneLoaded;
                UnityEngine.SceneManagement.SceneManager.sceneLoaded += _onSceneLoaded;
            }
            catch (Exception e) { Log("hook scenes failed: " + e.Message); }
        }

        private static void OnSceneLoaded(UnityEngine.SceneManagement.Scene s,
                                          UnityEngine.SceneManagement.LoadSceneMode mode)
        {
            try
            {
                bool had = _behaviour != null;
                EnsureBehaviour();
                Log("sceneLoaded: " + s.name + " mode=" + mode + " hadBehaviour=" + (had ? 1 : 0));
                if (_behaviour != null) _behaviour.OnSceneChanged(s.name);
            }
            catch (Exception e) { Log("sceneLoaded failed: " + e.Message); }
        }

        /// <summary>保证场景里有一个活着的 behaviour（没有就新建，并尽量让它跨场景存活）。</summary>
        public static void EnsureBehaviour()
        {
            if (_behaviour != null) return;
            var go = new GameObject("BenchWarp");
            try { UnityEngine.Object.DontDestroyOnLoad(go); }
            catch (Exception e) { Log("DontDestroyOnLoad failed: " + e.Message); }
            _behaviour = go.AddComponent<BenchWarpBehaviour>();
        }

        internal static void Register(BenchWarpBehaviour b) { _behaviour = b; }

        internal static void Unregister(BenchWarpBehaviour b)
        {
            if (!ReferenceEquals(_behaviour, b)) return;
            _behaviour = null;
            // 单行日志同步到 Player.log，方便判断「是不是被场景卸载带走的」
            Log("behaviour destroyed");
        }

        public static string DataDir
        {
            get
            {
                try { return Application.persistentDataPath; }
                catch { return null; }
            }
        }

        public static void Log(string msg)
        {
            try
            {
                // 单行短消息再同步一份到 Unity 日志：万一写文件那条路出问题
                // （占用、权限、杀软），Player.log 里还能看到 mod 是不是活着。
                if (!string.IsNullOrEmpty(msg) && msg.Length < 300 && msg.IndexOf('\n') < 0)
                {
                    try { UnityEngine.Debug.Log("[BenchWarp] " + msg); } catch { }
                }
                string line = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + msg + Environment.NewLine;
                string dir = DataDir;
                if (string.IsNullOrEmpty(dir)) return;
                File.AppendAllText(Path.Combine(dir, "BenchWarp.log"), line, Encoding.UTF8);
            }
            catch { }
        }
    }

    internal sealed class BenchEntry
    {
        public string Scene;
        public string Marker;
        public int Source;          // 0=存档/运行时确认  1=全量表（未确认）

        // 每帧刷新的屏幕坐标（GUI 坐标，左上角为原点）
        public bool OnMap;
        public Vector2 Gui;
        public bool IsCurrent;

        public BenchEntry(string scene, string marker, int source)
        {
            Scene = scene;
            Marker = marker;
            Source = source;
        }
    }

    public sealed class BenchWarpBehaviour : MonoBehaviour
    {
        private readonly Dictionary<string, string> _markers =
            new Dictionary<string, string>(StringComparer.Ordinal);
        private readonly List<BenchEntry> _benches = new List<BenchEntry>();
        private readonly Dictionary<string, Transform> _blocks =
            new Dictionary<string, Transform>(StringComparer.Ordinal);
        private readonly Dictionary<string, SpriteRenderer> _blockSprites =
            new Dictionary<string, SpriteRenderer>(StringComparer.Ordinal);
        private readonly Dictionary<string, RectTransform> _blockRects =
            new Dictionary<string, RectTransform>(StringComparer.Ordinal);

        private GameMap _map;
        private Camera _cam;

        // GameMap 里 14 个区域 Transform。哪个 activeSelf 就是当前显示的区域，
        // 全都不 active 说明地图没开。用字段名而不是层级遍历，是因为这些对象未必是直接子级。
        private static readonly string[] AreaFieldNames =
        {
            "areaAncientBasin", "areaCity", "areaCliffs", "areaCrossroads", "areaCrystalPeak",
            "areaDeepnest", "areaFogCanyon", "areaFungalWastes", "areaGreenpath", "areaKingdomsEdge",
            "areaQueensGardens", "areaRestingGrounds", "areaDirtmouth", "areaWaterways"
        };
        private FieldInfo[] _areaFields;
        private bool _mapWasOpen;
        private float _nextRebuild;
        private float _cool;
        private int _hover = -1;
        private string _msg = "";
        private float _msgUntil;
        private string _mapPath;
        private string _lastScene;
        // 诊断面板默认关闭；玩的时候按 F1 打开，再按一次隐藏。
        // 面板里的 area/compass/blocks/icons 就是排查「图标没出来」「光标不消失」用的现场数据。
        private bool _diag = false;
        private Texture2D _px;
        private GUIStyle _label;
        private GUIStyle _diagStyle;
        private Font _cnFont;
        private bool _cnFontTried;

        // GameMap 的实例缓存。
        // ⚠ 教训：Resources.FindObjectsOfTypeAll 会把「资源/prefab」也返回，
        // 那种对象的 activeInHierarchy 恒为 false。早先版本把第一个拿到的实例永久缓存下来，
        // 结果永远取到 prefab，IsMapOpen() 永远 false —— F1 面板和光标就全被挡在 return 之后。
        // 现在只保留「真正在已加载场景里」的实例，并且定期刷新，绝不长期相信一次查找结果。
        private GameMap[] _mapInstances;
        private float _nextMapScan;
        private string _mapDiag = "maps=?";
        private int _drawnIcons;

        // ---- 运行时对象转储（诊断用）----
        // 这个版本的地图 UI 完全是 PlayMaker FSM 直接 SetActive 对象，C# 侧没有任何状态可读，
        // GameMap 类只剩一个 prefab 残骸。所以只能靠「开图前后对象树有什么不一样」来定位它。
        private float _lastDump = -999f;
        private bool _autoDumped;
        private string _sceneName = "";
        private float _sceneEntered;
        private int _dumpCount;
        private object _iaActions;
        private FieldInfo _qmField;
        private PropertyInfo _qmPressed;
        private bool _inputProbed;

        private string _pendingScene;
        private string _pendingMarker;
        private float _pendingAt;

        // 本次「打开地图」是否是在长椅上发起的。
        // 之所以不在每一帧都要求 atBench：万游戏在打开地图时清掉 atBench，功能就会整个失效。
        // 改为在「地图打开的那一瞬间」判定一次，并允许最近 1 秒内刚坐下/刚离开的容差。
        private bool _sessionResting;
        private float _lastBenchAt = -999f;

        // 光标控制：游戏 InputHandler.OnGUI 里每帧都调 SetCursorVisible(false) 把光标藏掉
        // （地图既不算 isMenuScene 也不算 isPaused，正好落在「无条件隐藏」那一支），
        // 而且它是 Cursor.visible = false 加 Cursor.lockState = Locked —— 光设 visible 没用。
        //
        // 判断「系统光标能不能用」的时机很关键：
        //   Update → LateUpdate → OnGUI。所以「上一帧 OnGUI 结束后光标到底是不是可见的」，
        //   只能在下一帧的 Update 里读到（那之间的修改只有上一帧的 OnGUI）。
        //   若在 Update 里读到可见 → 说明我们已经排在游戏之后，系统光标可靠，直接用它；
        //   若读到隐藏 → 说明游戏在我们之后又藏了一次，那就只能自己画一个箭头。
        private int _cursorHiddenStreak;

        // 心跳：每 10 秒写一行，用来确认「进游戏后 mod 到底还活着吗」。
        // 之前所有判断都建立在一个未经验证的假设上 —— behaviour 在关卡场景里还活着。
        private float _nextBeat;

        // 地图判定 / 缓存用
        private int _lastAreaOn = -1;       // 本帧激活的区域数（IsMapOpen 里填）
        private int _lastAreaTotal;
        private int _cachedAreaOn = -1;     // 缓存地图块时激活的区域数；变了就重建
        private float _nextProjLog;
        private bool _cursorTook;           // 是否正在接管光标（会话结束要还给游戏）

        private void Awake()
        {
            Bootstrap.Register(this);
        }

        private void OnDestroy()
        {
            Bootstrap.Unregister(this);
        }

        /// <summary>每次场景加载后重置与场景相关的状态（由 Bootstrap.OnSceneLoaded 调用）。</summary>
        public void OnSceneChanged(string sceneName)
        {
            try
            {
                _sceneName = sceneName;
                _sceneEntered = Time.unscaledTime;
                _autoDumped = false;
                _mapInstances = null;
                _map = null;
                _cam = null;
                _sessionResting = false;
                _mapWasOpen = false;
                ClearMapCache();
                _nextBeat = Time.unscaledTime + 3f;
            }
            catch (Exception e) { Bootstrap.Log("OnSceneChanged failed: " + e.Message); }
        }

        private void Start()
        {
            try
            {
                _mapPath = Path.Combine(Bootstrap.DataDir ?? ".", "BenchWarp_benches.txt");
                LoadMap();
                Bootstrap.Log("behaviour ready, runtime markers: " + _markers.Count
                    + ", table scenes: " + BenchTable.Map.Count);
                var enc = ReadEncounteredBench(PlayerData.instance);
                if (enc == null) Bootstrap.Log("scenesEncounteredBench: <unavailable>");
                else Bootstrap.Log("scenesEncounteredBench: " + enc.Count + " scene(s): " + Shorten(enc));
            }
            catch (Exception e)
            {
                Bootstrap.Log("Start failed: " + e);
            }
        }

        private void Update()
        {
            try
            {
                if (_cool > 0f) _cool -= Time.unscaledDeltaTime;
                TrackBench();
                ScanSceneMarkers();
                ProcessPending();

                if (IsResting()) _lastBenchAt = Time.unscaledTime;

                bool open = IsMapOpen();
                bool resting = IsResting() || (Time.unscaledTime - _lastBenchAt) < 1.0f;

                // 「休息中开图」这件事只锁一次：
                // 只要同时满足「地图开着」和「正坐在长椅上」，就开启本次会话，直到地图关闭为止。
                // 不依赖 open 的跳变 —— 万一某些版本里地图状态一直读成 true，也不会漏掉触发。
                if (open && resting && !_sessionResting)
                {
                    _sessionResting = true;
                    ClearMapCache();
                    _nextRebuild = 0f;
                    Bootstrap.Log("session start: resting, atBench=" + IsResting()
                        + " gap=" + (Time.unscaledTime - _lastBenchAt).ToString("F2"));
                }
                else if (!open && _sessionResting)
                {
                    _sessionResting = false;
                    ClearMapCache();
                }

                if (open != _mapWasOpen)
                {
                    _mapWasOpen = open;
                    _hover = -1;
                    Bootstrap.Log("map " + (open ? "opened" : "closed") + " | " + _mapDiag);
                }

                bool active = open && _sessionResting;
                TrackCursorState(active);

                // 会话结束（关图 / 离开长椅）就把光标还给游戏。
                // 之前只在自己 OnDisable 时归还，结果下了长椅光标还挂在屏幕上。
                if (active) _cursorTook = true;
                else if (_cursorTook)
                {
                    _cursorTook = false;
                    try
                    {
                        UnityEngine.Cursor.visible = false;
                        UnityEngine.Cursor.lockState = UnityEngine.CursorLockMode.Locked;
                    }
                    catch { }
                }

                // 心跳：每 10 秒一行。只要日志里还在滚，就说明 behaviour 活着、Update 在跑。
                if (Time.unscaledTime >= _nextBeat)
                {
                    _nextBeat = Time.unscaledTime + 30f;
                    Bootstrap.Log("beat scene=" + CurrentScene() + " open=" + (open ? 1 : 0)
                        + " " + _mapDiag + " atBench=" + (IsResting() ? 1 : 0)
                        + " session=" + (_sessionResting ? 1 : 0)
                        + " ts=" + Time.timeScale.ToString("F2")
                        + " paused=" + (GameManager.instance != null && GameManager.instance.isPaused ? 1 : 0));
                }

                // 诊断转储：每个非菜单场景进一次，抓「地图关闭」的对照。
                // 原来固定在进游戏 8 秒，那时还在开场动画（Pre_Menu_Intro）里，白抓。
                if (_diag && !_autoDumped && _dumpCount < 8 && Time.unscaledTime - _sceneEntered > 15f
                    && !IsMenuScene())
                {
                    _autoDumped = true;
                    _dumpCount++;
                    DumpWorld("auto");
                }
                if (_diag && MapKeyPressed()) DumpWorld("quickMap");

                // F1 = 诊断面板。刻意放在「地图是否打开」的判断之前，
                // 这样即使地图状态识别失败，玩家也能按 F1 看到真实情况。
                var kb = UnityEngine.InputSystem.Keyboard.current;
                if (kb != null && kb[UnityEngine.InputSystem.Key.F1].wasPressedThisFrame)
                {
                    _diag = !_diag;
                    Bootstrap.Log("diag=" + _diag + " | " + DiagLine(open, active));
                    if (_diag) DumpWorld("f1");
                }

                // 不是从长椅上打开的地图 → 完全不介入，保持原版行为
                if (!active) return;

                if (_benches.Count == 0) Rebuild();

                // 地图块缓存必须跟着「当前激活的区域集合」重建：
                // 地图刚打开时区域是逐帧激活的，第一次可能只抓到当前区域（实测只缓存到 1 个区域的块），
                // 之后如果只判断「缓存非空就不重建」，长椅块就永远缺 —— 图标一个都画不出来。
                if ((_blocks.Count == 0 || _cachedAreaOn != _lastAreaOn) && Time.unscaledTime >= _nextRebuild)
                {
                    CacheSceneBlocks();
                    _cachedAreaOn = _lastAreaOn;
                    _nextRebuild = Time.unscaledTime + 0.25f;
                }

                UpdateIconPositions();
                UpdateHover();
                HandleClick();

                if (_diag && Time.unscaledTime >= _nextProjLog)
                {
                    _nextProjLog = Time.unscaledTime + 3f;
                    LogProjectionDiag();
                }
            }
            catch (Exception e)
            {
                Bootstrap.Log("Update failed: " + e);
            }
        }

        private void ClearMapCache()
        {
            _hover = -1;
            _cachedAreaOn = -1;
            _benches.Clear();
            _blocks.Clear();
            _blockSprites.Clear();
            _blockRects.Clear();
            _drawnIcons = 0;
        }

        // ------------------------------------------------------------ 诊断转储
        private static string Flag(GameObject go)
        {
            try
            {
                if (go.activeInHierarchy) return "ON ";
                return go.activeSelf ? "self" : "off";
            }
            catch { return "?  "; }
        }

        private static string Comps(GameObject go)
        {
            try
            {
                var cs = go.GetComponents<Component>();
                var sb = new StringBuilder();
                int n = 0;
                for (int i = 0; i < cs.Length; i++)
                {
                    var c = cs[i];
                    if (c == null) continue;
                    if (n++ > 0) sb.Append(",");
                    sb.Append(c.GetType().Name);
                    if (n >= 7) { sb.Append(",..."); break; }
                }
                return sb.ToString();
            }
            catch { return "?"; }
        }

        /// <summary>反射探测 InputHandler.inputActions.quickMap（游戏的地图键动作）。</summary>
        private void ProbeInput()
        {
            if (_inputProbed) return;
            _inputProbed = true;
            try
            {
                var t = typeof(InputHandler);
                var ff = t.GetField("Instance", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
                object ih = ff != null ? ff.GetValue(null) : null;
                if (ih == null) { Bootstrap.Log("input probe: no InputHandler.Instance"); return; }

                var af = t.GetField("inputActions", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
                if (af == null) { Bootstrap.Log("input probe: no inputActions field"); return; }
                _iaActions = af.GetValue(ih);
                if (_iaActions == null) { Bootstrap.Log("input probe: inputActions is null"); return; }

                _qmField = _iaActions.GetType().GetField("quickMap", BindingFlags.Public | BindingFlags.Instance);
                if (_qmField == null) { Bootstrap.Log("input probe: no quickMap field"); return; }

                Bootstrap.Log("input probe: quickMap ok (" + _iaActions.GetType().Name + ")");
            }
            catch (Exception e) { Bootstrap.Log("input probe failed: " + e.Message); }
        }

        private bool MapKeyPressed()
        {
            ProbeInput();
            if (_qmField == null || _iaActions == null) return false;
            try
            {
                object qm = _qmField.GetValue(_iaActions);
                if (qm == null) return false;
                if (_qmPressed == null)
                    _qmPressed = qm.GetType().GetProperty("WasPressed", BindingFlags.Public | BindingFlags.Instance);
                if (_qmPressed == null) return false;
                return (bool)_qmPressed.GetValue(qm);
            }
            catch { return false; }
        }

        /// <summary>
        /// 把「地图可能长什么样」的相关对象全量写进日志。
        /// 这个版本的地图没有 C# 状态可读，只能靠开图前后的对象树对照把它认出来。
        /// </summary>
        private void DumpWorld(string reason)
        {
            if (Time.unscaledTime - _lastDump < 2f && reason != "force") return;
            _lastDump = Time.unscaledTime;

            var sb = new StringBuilder();
            sb.Append("==== dump [").Append(reason).Append("] scene=").Append(CurrentScene())
              .Append(" atBench=").Append(IsResting() ? 1 : 0)
              .Append(" timeScale=").Append(Time.timeScale.ToString("F2"))
              .Append(" quickMapKey=").Append(MapKeyPressed() ? 1 : 0);
            try { sb.Append(" uiState=").Append(UIManager.instance != null ? UIManager.instance.uiState.ToString() : "?"); } catch { }
            try { sb.Append(" paused=").Append(GameManager.instance != null && GameManager.instance.isPaused ? 1 : 0); } catch { }
            sb.AppendLine();

            sb.AppendLine("-- root objects --");
            try
            {
                var roots = UnityEngine.SceneManagement.SceneManager.GetActiveScene().GetRootGameObjects();
                int rn = 0;
                foreach (var r in roots)
                {
                    if (r == null) continue;
                    sb.AppendLine("  [" + Flag(r) + "] " + r.name + " :: " + Comps(r));
                    if (++rn >= 40) break;
                }
            }
            catch (Exception e) { sb.AppendLine("  roots failed: " + e.Message); }

            sb.AppendLine("-- canvases --");
            try
            {
                var cvs = Resources.FindObjectsOfTypeAll<Canvas>();
                int cn = 0;
                foreach (var cv in cvs)
                {
                    if (cv == null) continue;
                    var go = cv.gameObject;
                    if (go == null) continue;
                    sb.AppendLine("  [" + Flag(go) + "] " + PathOf(cv.transform) + " mode=" + cv.renderMode);
                    if (++cn >= 25) break;
                }
            }
            catch (Exception e) { sb.AppendLine("  canvases failed: " + e.Message); }

            sb.AppendLine("-- name~map --");
            try
            {
                var trs = Resources.FindObjectsOfTypeAll<Transform>();
                int mn = 0;
                foreach (var tr in trs)
                {
                    if (tr == null) continue;
                    string nm;
                    try { nm = tr.gameObject.name; } catch { continue; }
                    if (string.IsNullOrEmpty(nm)) continue;
                    if (nm.IndexOf("map", StringComparison.OrdinalIgnoreCase) < 0) continue;
                    sb.AppendLine("  [" + Flag(tr.gameObject) + "] " + PathOf(tr) + " :: " + Comps(tr.gameObject));
                    if (++mn >= 45) { sb.AppendLine("  ...truncated"); break; }
                }
                if (mn == 0) sb.AppendLine("  (none)");
            }
            catch (Exception e) { sb.AppendLine("  map scan failed: " + e.Message); }

            sb.AppendLine("-- areas --");
            try
            {
                var mm = FindMap();
                if (mm == null) sb.AppendLine("  (no GameMap)");
                else
                {
                    sb.AppendLine("  map=" + PathOf(mm.transform) + " selfOn=" + (mm.gameObject.activeSelf ? 1 : 0)
                        + " inHierarchy=" + (mm.gameObject.activeInHierarchy ? 1 : 0));
                    foreach (var tr in GetAreas(mm))
                    {
                        if (tr == null) { sb.AppendLine("  <null>"); continue; }
                        sb.AppendLine("  " + tr.name + " selfOn=" + (tr.gameObject.activeSelf ? 1 : 0)
                            + " inHierarchy=" + (tr.gameObject.activeInHierarchy ? 1 : 0)
                            + " children=" + tr.childCount);
                    }
                }
            }
            catch (Exception e) { sb.AppendLine("  areas failed: " + e.Message); }

            Bootstrap.Log(sb.ToString());
        }

        // ------------------------------------------------------------ 光标
        /// <summary>
        /// 渲染前的最后一刻再抢一次光标。
        /// 游戏的 InputHandler.OnGUI 有可能排在我们之后（脚本顺序不确定），
        /// 那时 OnGUI 里设的会被它再覆盖掉，只有更晚的 OnPreCull 才压得住。
        /// </summary>
        private void OnPreCull()
        {
            try
            {
                if (_sessionResting && _mapWasOpen) ApplyCursor(true);
            }
            catch { }
        }

        /// <summary>
        /// 在 Update 里判断「上一帧结束时系统光标有没有被游戏收回」。
        /// 只在 Update 里读 Cursor.visible 才准：那读到的就是上一帧 OnGUI 结束后的最终状态。
        /// </summary>
        private void TrackCursorState(bool want)
        {
            if (!want) { _cursorHiddenStreak = 0; return; }
            if (UnityEngine.Cursor.visible) _cursorHiddenStreak = 0;
            else if (_cursorHiddenStreak < 300) _cursorHiddenStreak++;
        }

        /// <summary>系统光标被游戏每帧压回去时，改为自绘箭头。</summary>
        private bool NeedSelfCursor { get { return _cursorHiddenStreak >= 3; } }

        /// <summary>在 OnGUI 里尽量把系统光标抢回来；抢不过由 NeedSelfCursor 兜底。</summary>
        private void ApplyCursor(bool want)
        {
            if (!want) return;
            try
            {
                // 游戏用的是 Locked；Locked 状态下设 visible 会被压掉，必须先解锁
                if (UnityEngine.Cursor.lockState != UnityEngine.CursorLockMode.None)
                    UnityEngine.Cursor.lockState = UnityEngine.CursorLockMode.None;
                if (!UnityEngine.Cursor.visible) UnityEngine.Cursor.visible = true;
            }
            catch { }
        }

        private void OnDisable()
        {
            // 交还给游戏：它每帧都会重设，这里只是别把「可见且解锁」的脏状态留下去
            try
            {
                _cursorHiddenStreak = 0;
                UnityEngine.Cursor.visible = false;
                UnityEngine.Cursor.lockState = UnityEngine.CursorLockMode.Locked;
            }
            catch { }
        }

        /// <summary>自绘光标：系统光标被游戏抢回去时用它，形状是常见的箭头。</summary>
        private void DrawCursor(float x, float y)
        {
            var prev = GUI.color;
            const int rows = 13;

            GUI.color = new Color(0f, 0f, 0f, 0.85f);
            for (int i = 0; i < rows; i++)
                GUI.DrawTexture(new Rect(x - 1f, y - 1f + i, i + 3f, 1f), Px);

            GUI.color = Color.white;
            for (int i = 0; i < rows; i++)
                GUI.DrawTexture(new Rect(x, y + i, i + 1f, 1f), Px);

            // 尾巴
            GUI.color = new Color(0f, 0f, 0f, 0.85f);
            GUI.DrawTexture(new Rect(x - 1f, y + rows - 2f, 6f, 9f), Px);
            GUI.color = Color.white;
            GUI.DrawTexture(new Rect(x, y + rows - 1f, 3f, 7f), Px);

            GUI.color = prev;
        }

        // ------------------------------------------------------------ 状态判断
        private bool IsResting()
        {
            try
            {
                var pd = PlayerData.instance;
                return pd != null && pd.atBench;
            }
            catch { return false; }
        }

        /// <summary>
        /// 重新枚举场景里的 GameMap 实例。
        /// Resources.FindObjectsOfTypeAll 连 prefab / 未加载资源都会返回，这里用 scene.IsValid()
        /// 把它们剔掉 —— 这正是早先「地图永远判定未打开」的元凶。
        /// </summary>
        private void RescanMaps()
        {
            var list = new List<GameMap>();
            int skipped = 0, nulls = 0;
            GameMap[] all = null;
            try
            {
                all = Resources.FindObjectsOfTypeAll<GameMap>();
                if (all != null)
                {
                    foreach (var m in all)
                    {
                        if (m == null) { nulls++; continue; }
                        var go = m.gameObject;
                        if (go == null) { nulls++; continue; }
                        UnityEngine.SceneManagement.Scene sc;
                        try { sc = go.scene; } catch { skipped++; continue; }
                        if (!sc.IsValid() || string.IsNullOrEmpty(sc.name)) { skipped++; continue; }
                        list.Add(m);
                    }
                }
            }
            catch (Exception e)
            {
                Bootstrap.Log("RescanMaps failed: " + e.Message);
            }

            bool changed = _mapInstances == null || _mapInstances.Length != list.Count;
            if (list.Count == 0 && all != null && all.Length > 0)
            {
                // scene 过滤把所有实例都剔掉了（极少见）。宁可退回「全部实例」也不要瞎掉：
                // prefab 的 activeInHierarchy 恒为 false，靠这一条仍然不会误判成「地图已打开」。
                list.Clear();
                foreach (var m in all) { if (m != null) list.Add(m); }
                Bootstrap.Log("RescanMaps: scene filter removed everything, fell back to all "
                    + list.Count + " instance(s)");
            }
            _mapInstances = list.ToArray();
            _nextMapScan = Time.unscaledTime + 2f;
            if (changed)
                Bootstrap.Log("map instances: " + _mapInstances.Length + " in scene, "
                    + skipped + " asset/prefab skipped, " + nulls + " null");
        }

        /// <summary>
        /// 场景里已经有 GameMap 实例就不再重扫 —— 那次扫描要遍历全部对象，很贵。
        /// 只有「一个都没找到」时才每 2 秒重试一次。
        /// </summary>
        private void EnsureMaps()
        {
            if (_mapInstances != null && _mapInstances.Length > 0) return;
            if (Time.unscaledTime < _nextMapScan) return;
            RescanMaps();
        }

        private GameMap FindMap()
        {
            try
            {
                EnsureMaps();
                if (_mapInstances != null && _mapInstances.Length > 0)
                {
                    foreach (var m in _mapInstances)
                    {
                        if (m == null) continue;
                        _map = m;
                        break;
                    }
                }
            }
            catch (Exception e)
            {
                Bootstrap.Log("FindMap failed: " + e.Message);
            }
            return _map;
        }

        private static bool ReadBool(object o, string field)
        {
            try
            {
                var fi = o.GetType().GetField(field,
                    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
                if (fi == null || fi.FieldType != typeof(bool)) return false;
                return (bool)fi.GetValue(o);
            }
            catch { return false; }
        }

        private static string PathOf(Transform t)
        {
            try
            {
                var s = t.name;
                while (t.parent != null) { t = t.parent; s = t.name + "/" + s; }
                return s;
            }
            catch { return "?"; }
        }

        private void ResolveAreaFields()
        {
            if (_areaFields != null) return;
            var flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
            var list = new List<FieldInfo>();
            var missing = new List<string>();
            foreach (var n in AreaFieldNames)
            {
                var fi = typeof(GameMap).GetField(n, flags);
                if (fi != null) list.Add(fi); else missing.Add(n);
            }
            _areaFields = list.ToArray();
            Bootstrap.Log("area fields: resolved " + _areaFields.Length + "/" + AreaFieldNames.Length
                + (missing.Count > 0 ? ", missing=" + string.Join(",", missing.ToArray()) : ""));
        }

        /// <summary>取地图的 14 个区域 Transform；字段拿不到时退回直接子对象。</summary>
        private List<Transform> GetAreas(GameMap m)
        {
            var list = new List<Transform>();
            if (m == null) return list;
            ResolveAreaFields();
            if (_areaFields.Length > 0)
            {
                foreach (var fi in _areaFields)
                {
                    Transform tr = null;
                    try { tr = fi.GetValue(m) as Transform; } catch { }
                    if (tr != null) list.Add(tr);
                }
            }
            if (list.Count == 0)
            {
                var t = m.transform;
                for (int i = 0; i < t.childCount; i++)
                {
                    var c = t.GetChild(i);
                    if (c != null) list.Add(c);
                }
            }
            return list;
        }

        /// <summary>
        /// 地图是否打开。
        /// 游戏打开地图时 GameMap 被激活、并把它 14 个区域里相关的 SetActive(true)；
        /// 关闭时 CloseQuickMap 会把 14 个区域全部 SetActive(false) 并清掉 displayingCompass。
        /// 所以判据是「激活的 GameMap 实例上，任一 area 激活 或 displayingCompass 为真」。
        /// 这里不再把某一次查找结果当成永久事实 —— 每次都会在必要时重新枚举。
        /// </summary>
        private bool IsMapOpen()
        {
            try
            {
                EnsureMaps();
                if (_mapInstances == null) return false;

                int live = 0, areaOn = 0;
                for (int i = 0; i < _mapInstances.Length; i++)
                {
                    var m = _mapInstances[i];
                    if (m == null) continue;
                    var go = m.gameObject;
                    if (go == null) continue;

                    bool goActive = false;
                    try { goActive = go.activeInHierarchy; } catch { }
                    if (goActive) live++;

                    // ⚠ 注意：GameMap 组件所在的对象实测是「常驻未激活」的（面板上 live=0），
                    // 它只是持有 14 个 areaXxx 引用，而这些区域对象挂在别的已激活父级下。
                    // 所以这里绝对不能要求 goActive —— 否则区域一次都不会被检查（areaFields 一直是 "-"）。
                    var areas = GetAreas(m);
                    int total = areas.Count, on = 0;
                    for (int a = 0; a < areas.Count; a++)
                    {
                        var tr = areas[a];
                        if (tr == null) continue;
                        try { if (tr.gameObject.activeInHierarchy) on++; } catch { }
                    }
                    areaOn = on;

                    // area 判据：关图时只有「当前所在区域」那一个处于激活状态（实测 1/20），
                    // 开图时几乎所有区域一起激活（实测 19/20）。所以阈值取 3 就足够区分，
                    // 原来「on>0 就算开」把关图状态也当成了开图 —— 那是「下长椅后光标还在」的原因。
                    // 另外 displayingCompass 只在开图时为真，作为第二判据。
                    bool compass = ReadBool(m, "displayingCompass");
                    _lastAreaOn = on;
                    _lastAreaTotal = total;
                    _mapDiag = "area=" + on + "/" + total + " compass=" + (compass ? 1 : 0)
                        + " live=" + live;

                    if (compass || on >= 3)
                    {
                        _map = m;
                        return true;
                    }
                }

                _mapDiag = "maps=" + _mapInstances.Length + " live=" + live
                    + " area=" + areaOn + "/" + _lastAreaTotal + " compass=0";
            }
            catch (Exception e)
            {
                Bootstrap.Log("IsMapOpen failed: " + e.Message);
            }
            return false;
        }

        private Camera FindCamera()
        {
            if (_cam != null && _cam.isActiveAndEnabled) return _cam;
            try
            {
                var m = FindMap();
                if (m != null)
                {
                    var cv = m.GetComponentInParent<Canvas>();
                    if (cv != null && cv.renderMode != RenderMode.ScreenSpaceOverlay && cv.worldCamera != null)
                    {
                        _cam = cv.worldCamera;
                        return _cam;
                    }
                }
                // 2) 地图块是 SpriteRenderer 画的，拍它的是 HUD 相机；Camera.main 未必是它
                var hud = FindHudCamera();
                if (hud != null)
                {
                    _cam = hud;
                    Bootstrap.Log("hud camera: " + hud.name + " ortho=" + hud.orthographic);
                    return _cam;
                }
                if (Camera.main != null) { _cam = Camera.main; return _cam; }
                var cams = Camera.allCameras;
                if (cams != null && cams.Length > 0)
                {
                    _cam = cams[0];
                    return _cam;
                }
            }
            catch (Exception e)
            {
                Bootstrap.Log("FindCamera failed: " + e.Message);
            }
            return null;
        }

        /// <summary>从 GameCameras 里取 HUD 相机（地图 SpriteRenderer 就是它拍的）。</summary>
        private Camera FindHudCamera()
        {
            try
            {
                var t = typeof(GameManager).Assembly.GetType("GameCameras");
                if (t != null)
                {
                    object o = null;
                    var pi = t.GetProperty("instance", BindingFlags.Public | BindingFlags.Static);
                    if (pi != null) o = pi.GetValue(null, null);
                    if (o == null)
                    {
                        var fi = t.GetField("instance", BindingFlags.Public | BindingFlags.Static | BindingFlags.NonPublic);
                        if (fi != null) o = fi.GetValue(null);
                    }
                    if (o != null)
                    {
                        foreach (var n in new string[] { "hudCamera", "HUDCamera", "hudCam" })
                        {
                            var cf = t.GetField(n, BindingFlags.Public | BindingFlags.Instance | BindingFlags.NonPublic);
                            if (cf == null) continue;
                            var c = cf.GetValue(o) as Camera;
                            if (c != null) return c;
                        }
                    }
                }
            }
            catch { }

            try
            {
#pragma warning disable 618
                foreach (var c in UnityEngine.Object.FindObjectsOfType<Camera>())
#pragma warning restore 618
                {
                    if (c == null) continue;
                    string n = c.gameObject.name;
                    if (n.IndexOf("HUD", StringComparison.OrdinalIgnoreCase) >= 0) return c;
                }
            }
            catch { }
            return null;
        }

        // ------------------------------------------------------------ 地图块缓存
        /// <summary>把地图「区域 → 场景块」按名字索引起来（只收当前可见的）。</summary>
        private void CacheSceneBlocks()
        {
            int before = _blocks.Count;
            _blocks.Clear();
            _blockSprites.Clear();
            _blockRects.Clear();
            var m = FindMap();
            if (m == null) return;

            int areas = 0, scenes = 0;
            foreach (var area in GetAreas(m))
            {
                if (area == null || !area.gameObject.activeInHierarchy) continue;
                areas++;
                for (int j = 0; j < area.childCount; j++)
                {
                    var sb = area.GetChild(j);
                    if (sb == null) continue;
                    string name = sb.gameObject.name;
                    if (string.IsNullOrEmpty(name) || _blocks.ContainsKey(name)) continue;
                    _blocks[name] = sb;
                    var sr = sb.GetComponent<SpriteRenderer>();
                    if (sr != null) _blockSprites[name] = sr;
                    var rt = sb.GetComponent<RectTransform>();
                    if (rt != null) _blockRects[name] = rt;
                    scenes++;
                }
            }
            if (_blocks.Count != before)
                Bootstrap.Log("map blocks cached: " + areas + " area(s), " + _blocks.Count
                    + " scene block(s) [" + scenes + " child seen]");
        }

        private bool BlockVisible(Transform sb)
        {
            if (sb == null) return false;
            return sb.gameObject.activeInHierarchy;
        }

        /// <summary>把场景块的世界位置投影到屏幕（GUI 坐标）。</summary>
        private bool ProjectBlock(string scene, out Vector2 gui)
        {
            gui = Vector2.zero;
            Transform sb;
            if (!_blocks.TryGetValue(scene, out sb) || !BlockVisible(sb)) return false;

            try
            {
                // 1) UI 元素：直接走 RectTransform
                RectTransform rt;
                if (_blockRects.TryGetValue(scene, out rt) && rt != null)
                {
                    var cv = sb.GetComponentInParent<Canvas>();
                    Camera cam = null;
                    if (cv != null && cv.renderMode != RenderMode.ScreenSpaceOverlay) cam = cv.worldCamera;
                    Vector2 sp = RectTransformUtility.WorldToScreenPoint(cam, rt.position);
                    gui = new Vector2(sp.x, Screen.height - sp.y);
                    return true;
                }

                // 2) Sprite 渲染的地图块（本作就是这种）
                SpriteRenderer sr;
                Vector3 world;
                if (_blockSprites.TryGetValue(scene, out sr) && sr != null) world = sr.bounds.center;
                else world = sb.position;

                var c = FindCamera();
                if (c == null) return false;
                Vector3 sp3 = c.WorldToScreenPoint(world);
                if (sp3.z < 0f) return false;
                gui = new Vector2(sp3.x, Screen.height - sp3.y);
                return true;
            }
            catch (Exception e)
            {
                Bootstrap.Log("ProjectBlock(" + scene + ") failed: " + e.Message);
                return false;
            }
        }

        private void UpdateIconPositions()
        {
            string cur = CurrentScene();
            for (int i = 0; i < _benches.Count; i++)
            {
                var e = _benches[i];
                e.IsCurrent = string.Equals(e.Scene, cur, StringComparison.Ordinal);
                Vector2 gui;
                e.OnMap = ProjectBlock(e.Scene, out gui);
                e.Gui = gui;
            }
        }

        /// <summary>
        /// 投影诊断：图标画不出来到底是哪一环断了 ——
        /// 长椅的场景名对不上地图块 / 块被隐藏 / 投影落在屏幕外。
        /// </summary>
        private void LogProjectionDiag()
        {
            try
            {
                int hasBlock = 0, visible = 0, onMap = 0, off = 0;
                var miss = new StringBuilder();
                for (int i = 0; i < _benches.Count; i++)
                {
                    var e = _benches[i];
                    Transform sb;
                    if (!_blocks.TryGetValue(e.Scene, out sb) || sb == null)
                    {
                        if (miss.Length < 150) miss.Append(miss.Length > 0 ? " " : "").Append("noBlock:").Append(e.Scene);
                        continue;
                    }
                    hasBlock++;
                    if (!BlockVisible(sb))
                    {
                        if (miss.Length < 150) miss.Append(miss.Length > 0 ? " " : "").Append("hidden:").Append(e.Scene);
                        continue;
                    }
                    visible++;
                    if (e.OnMap) onMap++;
                    else
                    {
                        off++;
                        if (miss.Length < 150) miss.Append(miss.Length > 0 ? " " : "").Append("offscr:").Append(e.Scene);
                    }
                }

                var c = FindCamera();
                string cam = c == null ? "null"
                    : c.name + "(ortho=" + (c.orthographic ? 1 : 0) + ",depth=" + c.depth.ToString("F1") + ")";

                string cur = CurrentScene();
                Transform hit;
                string curInfo = "curBlock=none";
                if (_blocks.TryGetValue(cur, out hit) && hit != null)
                {
                    Vector3 w = hit.position;
                    SpriteRenderer sr;
                    if (_blockSprites.TryGetValue(cur, out sr) && sr != null) w = sr.bounds.center;
                    Vector3 sp3 = c != null ? c.WorldToScreenPoint(w) : Vector3.zero;
                    curInfo = cur + " world=" + w.ToString("F0") + " screen=" + sp3.ToString("F0");
                }

                Bootstrap.Log("proj: benches=" + _benches.Count + " block=" + hasBlock
                    + " visible=" + visible + " onMap=" + onMap + " off=" + off
                    + " blocks=" + _blocks.Count + " areas=" + _lastAreaOn + "/" + _lastAreaTotal
                    + " cam=" + cam + " | " + curInfo + " | miss=" + miss.ToString());
            }
            catch (Exception e) { Bootstrap.Log("proj diag failed: " + e.Message); }
        }

        private static string CurrentScene()
        {
            try { return UnityEngine.SceneManagement.SceneManager.GetActiveScene().name; }
            catch { return ""; }
        }

        /// <summary>菜单 / 开场动画场景（Menu_Title、Pre_Menu_Intro 等）。这些场景里不需要转储。</summary>
        private bool IsMenuScene()
        {
            try
            {
                string s = string.IsNullOrEmpty(_sceneName) ? CurrentScene() : _sceneName;
                if (string.IsNullOrEmpty(s)) return true;
                return s.IndexOf("Menu", StringComparison.OrdinalIgnoreCase) >= 0;
            }
            catch { return true; }
        }

        private void UpdateHover()
        {
            _hover = -1;
            var mouse = UnityEngine.InputSystem.Mouse.current;
            if (mouse == null) return;
            Vector2 p = mouse.position.ReadValue();
            Vector2 gui = new Vector2(p.x, Screen.height - p.y);
            float best = 15f;
            for (int i = 0; i < _benches.Count; i++)
            {
                var e = _benches[i];
                if (!e.OnMap || e.IsCurrent) continue;
                float d = Vector2.Distance(gui, e.Gui);
                if (d < best) { best = d; _hover = i; }
            }
        }

        // ------------------------------------------------------------ 点击
        private void HandleClick()
        {
            var mouse = UnityEngine.InputSystem.Mouse.current;
            if (mouse == null || !mouse.leftButton.wasPressedThisFrame) return;
            if (_cool > 0f) return;

            Vector2 p = mouse.position.ReadValue();
            Vector2 gui = new Vector2(p.x, Screen.height - p.y);

            int best = -1;
            float bestDist = 15f;   // 命中半径（像素）
            for (int i = 0; i < _benches.Count; i++)
            {
                var e = _benches[i];
                if (!e.OnMap || e.IsCurrent) continue;
                float d = Vector2.Distance(gui, e.Gui);
                if (d < bestDist) { bestDist = d; best = i; }
            }
            if (best < 0) return;

            var pick = _benches[best];
            Bootstrap.Log("map click -> " + pick.Scene + " (marker=" + pick.Marker + ", dist=" + bestDist.ToString("F1") + ")");
            RequestWarp(pick);
        }

        // ------------------------------------------------------------ 传送
        private void RequestWarp(BenchEntry e)
        {
            _pendingScene = e.Scene;
            _pendingMarker = e.Marker;
            _pendingAt = Time.unscaledTime;
            SetMsg("Warping to " + e.Scene);
            CloseMap();
        }

        /// <summary>关闭地图。先试游戏自己的 CloseQuickMap，再兜底关子对象。</summary>
        private void CloseMap()
        {
            var m = FindMap();
            if (m == null) return;
            try
            {
                var mi = typeof(GameMap).GetMethod("CloseQuickMap",
                    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
                if (mi != null)
                {
                    mi.Invoke(m, null);
                    Bootstrap.Log("CloseQuickMap invoked");
                }
                else Bootstrap.Log("CloseQuickMap not found, falling back to SetActive");
            }
            catch (Exception e)
            {
                Bootstrap.Log("CloseQuickMap failed: " + e.Message);
            }

            // 兜底：把 14 个区域全部关掉（等价于视觉上的关闭）
            try
            {
                foreach (var area in GetAreas(m))
                {
                    if (area != null && area.gameObject.activeSelf) area.gameObject.SetActive(false);
                }
            }
            catch (Exception e)
            {
                Bootstrap.Log("fallback close failed: " + e.Message);
            }
        }

        /// <summary>等游戏时间恢复（地图关闭会解暂停），再执行传送。</summary>
        private void ProcessPending()
        {
            if (string.IsNullOrEmpty(_pendingScene)) return;
            float dt = Time.unscaledTime - _pendingAt;

            bool timeOk = Time.timeScale > 0f;
            if (!timeOk && dt < 0.6f) return;          // 再等一会儿让游戏自己恢复
            if (dt > 4f)
            {
                Bootstrap.Log("pending warp timed out: " + _pendingScene);
                _pendingScene = null;
                return;
            }

            if (!timeOk)
            {
                Bootstrap.Log("timeScale still 0 after " + dt.ToString("F2") + "s, forcing 1");
                Time.timeScale = 1f;
            }

            string scene = _pendingScene, marker = _pendingMarker;
            _pendingScene = null;
            _pendingMarker = null;
            DoWarp(scene, marker);
        }

        private void DoWarp(string scene, string marker)
        {
            if (string.IsNullOrEmpty(marker))
            {
                marker = "RestBench";
                Bootstrap.Log("marker unknown for " + scene + ", falling back to RestBench");
            }

            var pd = PlayerData.instance;
            var gm = GameManager.instance;
            var hc = HeroController.instance;
            if (pd == null || gm == null || hc == null)
            {
                SetMsg("Not in game yet.");
                return;
            }

            try
            {
                pd.SetBenchRespawn(marker, scene, 1, true);
                _cool = 1.5f;

                if (string.Equals(CurrentScene(), scene, StringComparison.Ordinal))
                {
                    gm.StartCoroutine(hc.Respawn());
                    SetMsg("Respawned at " + scene);
                }
                else
                {
                    gm.ReadyForRespawn(false);
                    SetMsg("Warping to " + scene);
                }
            }
            catch (Exception ex)
            {
                SetMsg("Warp failed: " + ex.Message);
                Bootstrap.Log("DoWarp failed: " + ex);
            }
        }

        private void SetMsg(string text)
        {
            _msg = text;
            _msgUntil = Time.unscaledTime + 3f;
            Bootstrap.Log(text);
        }

        // ------------------------------------------------------------ 记录长椅
        private void TrackBench()
        {
            var pd = PlayerData.instance;
            if (pd == null || !pd.atBench) return;
            string scene = pd.respawnScene;
            if (string.IsNullOrEmpty(scene)) return;

            string marker = null;
            try { marker = pd.respawnMarkerName; } catch { }
            if (string.IsNullOrEmpty(marker)) return;

            string old;
            if (_markers.TryGetValue(scene, out old) && old == marker) return;
            _markers[scene] = marker;
            SaveMap();
            Bootstrap.Log("recorded bench " + scene + " -> " + marker);
        }

        private void ScanSceneMarkers()
        {
            string scene = CurrentScene();
            if (string.IsNullOrEmpty(scene) || scene == _lastScene) return;
            _lastScene = scene;
            if (!BenchTable.Map.ContainsKey(scene)) return;

            try
            {
#pragma warning disable 618
                var all = UnityEngine.Object.FindObjectsOfType<RespawnMarker>();
#pragma warning restore 618
                if (all == null || all.Length == 0) return;

                string best = null;
                foreach (var rm in all)
                {
                    if (rm == null || rm.gameObject == null) continue;
                    string n = rm.gameObject.name;
                    if (string.IsNullOrEmpty(n)) continue;
                    string low = n.ToLowerInvariant();
                    if (low.IndexOf("bench", StringComparison.Ordinal) < 0) continue;
                    if (low.IndexOf("death respawn", StringComparison.Ordinal) >= 0) continue;
                    bool isRest = low.StartsWith("restbench", StringComparison.Ordinal);
                    if (best == null || isRest) { best = n; if (isRest) break; }
                }
                if (best == null) return;

                string old;
                if (_markers.TryGetValue(scene, out old) && old == best) return;
                _markers[scene] = best;
                SaveMap();
                Bootstrap.Log("scene scan: " + scene + " -> " + best);
            }
            catch (Exception e)
            {
                Bootstrap.Log("ScanSceneMarkers failed: " + e.Message);
            }
        }

        private static string Shorten(List<string> items)
        {
            if (items == null) return "";
            int n = Math.Min(items.Count, 15);
            string s = string.Join(", ", items.GetRange(0, n).ToArray());
            return items.Count > n ? s + " ...(+" + (items.Count - n) + ")" : s;
        }

        private static List<string> ReadEncounteredBench(PlayerData pd)
        {
            if (pd == null) return null;
            try
            {
                var fi = typeof(PlayerData).GetField("scenesEncounteredBench",
                    BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
                if (fi == null) { Bootstrap.Log("ReadEncounteredBench: field not found"); return null; }
                object obj = fi.GetValue(pd);
                if (obj == null) { Bootstrap.Log("ReadEncounteredBench: value is null"); return null; }
                var en = obj as IEnumerable;
                if (en == null)
                {
                    Bootstrap.Log("ReadEncounteredBench: not IEnumerable, actual " + obj.GetType().FullName);
                    return null;
                }
                var list = new List<string>();
                foreach (var it in en)
                {
                    string s = it as string;
                    if (!string.IsNullOrEmpty(s)) list.Add(s);
                }
                return list;
            }
            catch (Exception e)
            {
                Bootstrap.Log("ReadEncounteredBench failed: " + e);
                return null;
            }
        }

        private void LoadMap()
        {
            if (string.IsNullOrEmpty(_mapPath) || !File.Exists(_mapPath)) return;
            foreach (var raw in File.ReadAllLines(_mapPath, Encoding.UTF8))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line[0] == '#') continue;
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string scene = line.Substring(0, eq).Trim();
                string marker = line.Substring(eq + 1).Trim();
                if (scene.Length > 0 && marker.Length > 0) _markers[scene] = marker;
            }
        }

        private void SaveMap()
        {
            try
            {
                var sb = new StringBuilder();
                sb.AppendLine("# BenchWarp: scene=respawnMarker（自动维护，可删除以重建）");
                var keys = new List<string>(_markers.Keys);
                keys.Sort(StringComparer.Ordinal);
                foreach (var k in keys) sb.AppendLine(k + "=" + _markers[k]);
                File.WriteAllText(_mapPath, sb.ToString(), Encoding.UTF8);
            }
            catch (Exception e)
            {
                Bootstrap.Log("SaveMap failed: " + e);
            }
        }

        /// <summary>组装「已解锁长椅」列表：存档优先，读不到就用内嵌全表兜底。</summary>
        private void Rebuild()
        {
            _benches.Clear();
            var seen = new HashSet<string>(StringComparer.Ordinal);

            var encountered = ReadEncounteredBench(PlayerData.instance);
            if (encountered != null)
            {
                foreach (var s in encountered)
                {
                    if (string.IsNullOrEmpty(s) || !seen.Add(s)) continue;
                    _benches.Add(MakeEntry(s));
                }
            }

            if (_benches.Count == 0)
            {
                foreach (var s in BenchTable.Map.Keys)
                {
                    if (!seen.Add(s)) continue;
                    _benches.Add(MakeEntry(s));
                }
                Bootstrap.Log("Rebuild: save list empty -> full table, " + _benches.Count + " entries");
            }
            else
            {
                // 运行时记录到、但存档没列出的也补上
                foreach (var kv in _markers)
                {
                    if (!seen.Add(kv.Key)) continue;
                    _benches.Add(new BenchEntry(kv.Key, kv.Value, 0));
                }
                Bootstrap.Log("Rebuild: " + _benches.Count + " entries from save (+runtime)");
            }
        }

        private BenchEntry MakeEntry(string scene)
        {
            string m;
            if (_markers.TryGetValue(scene, out m) && !string.IsNullOrEmpty(m))
                return new BenchEntry(scene, m, 0);
            string[] cands;
            if (BenchTable.Map.TryGetValue(scene, out cands) && cands != null && cands.Length > 0)
                return new BenchEntry(scene, cands[0], 1);
            return new BenchEntry(scene, null, 1);
        }

        // ------------------------------------------------------------ 绘制
        private Texture2D Px
        {
            get
            {
                if (_px == null)
                {
                    _px = new Texture2D(1, 1);
                    _px.SetPixel(0, 0, Color.white);
                    _px.Apply();
                }
                return _px;
            }
        }

        private GUIStyle Label_()
        {
            if (_label == null)
            {
                _label = new GUIStyle(GUI.skin.label);
                _label.alignment = TextAnchor.UpperCenter;
                _label.fontSize = 11;
                _label.normal.textColor = Color.white;
                var f = CnFont();
                if (f != null) _label.font = f;   // Unity 内置字体不含中文，不换字体中文会显示成空白
            }
            return _label;
        }

        /// <summary>
        /// 取一个含中文的系统字体。Unity 默认 GUI 字体（Arial）没有中文字形，
        /// 直接画中文会变成一片空白 —— 之前「单击传送到 xxx」看不见就是这个原因。
        /// </summary>
        private Font CnFont()
        {
            if (_cnFontTried) return _cnFont;
            _cnFontTried = true;
            try
            {
                _cnFont = Font.CreateDynamicFontFromOSFont(new string[]
                {
                    "Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "SimSun",
                    "Noto Sans CJK SC", "Arial Unicode MS", "Arial"
                }, 14);
                Bootstrap.Log("ui font: " + (_cnFont != null ? _cnFont.name : "<null>"));
            }
            catch (Exception e)
            {
                Bootstrap.Log("ui font failed: " + e.Message);
            }
            return _cnFont;
        }

        /// <summary>F1 面板用的一行状态（同时写进日志，方便复查）。</summary>
        private string DiagLine(bool open, bool active)
        {
            return "scene=" + CurrentScene()
                + " atBench=" + (IsResting() ? 1 : 0)
                + " " + _mapDiag
                + " open=" + (open ? 1 : 0)
                + " active=" + (active ? 1 : 0)
                + " benches=" + _benches.Count
                + " icons=" + _drawnIcons
                + " blocks=" + _blocks.Count
                + " cursor=" + (NeedSelfCursor ? "self" : "system")
                + " vis=" + (UnityEngine.Cursor.visible ? 1 : 0)
                + " lock=" + UnityEngine.Cursor.lockState;
        }

        private void DrawDiagPanel(bool open, bool active, GUIStyle style)
        {
            string[] lines =
            {
                "BenchWarp v" + Bootstrap.ModVersion + "   (F1 = hide)",
                "scene   : " + CurrentScene(),
                "atBench : " + (IsResting() ? "yes" : "no")
                    + "    sessionResting: " + (_sessionResting ? "yes" : "no"),
                "map open: " + (open ? "YES" : "no") + "    " + _mapDiag,
                "benches : " + _benches.Count + "    icons drawn: " + _drawnIcons,
                "blocks  : " + _blocks.Count + "    areaFields: "
                    + (_areaFields == null ? "-" : _areaFields.Length.ToString() + "/14"),
                "cursor  : " + (NeedSelfCursor ? "SELF-DRAWN" : "system")
                    + "    visible=" + (UnityEngine.Cursor.visible ? 1 : 0)
                    + "    " + UnityEngine.Cursor.lockState,
                "screen  : " + Screen.width + "x" + Screen.height
            };

            if (_diagStyle == null)
            {
                _diagStyle = new GUIStyle(style);
                _diagStyle.alignment = TextAnchor.UpperLeft;
                _diagStyle.fontSize = 12;
            }

            float w = 560f;
            float h = 18f * lines.Length + 10f;
            var prev = GUI.color;
            GUI.color = new Color(0f, 0f, 0f, 0.72f);
            GUI.DrawTexture(new Rect(6f, 6f, w, h), Px);
            GUI.color = prev;

            for (int i = 0; i < lines.Length; i++)
                GUI.Label(new Rect(14f, 11f + i * 18f, w - 20f, 18f), lines[i], _diagStyle);
        }

        private void OnGUI()
        {
            try
            {
                // 光标必须在任何 return 之前处理：游戏的 InputHandler.OnGUI 每帧都在藏光标，
                // 只有和它同处 OnGUI 阶段才抢得回来。
                bool open = IsMapOpen();
                bool active = open && _sessionResting;
                ApplyCursor(active);

                if (Event.current == null || Event.current.type != EventType.Repaint) return;

                var style = Label_();

                // F1 诊断面板：任何状态都显示（旧版包在「地图已打开」分支里，所以按 F1 看着像没反应）
                if (_diag) DrawDiagPanel(open, active, style);

                // 提示语（传送时地图已经关了，所以必须画在 active 判断之前）
                if (_msg.Length > 0 && Time.unscaledTime < _msgUntil)
                {
                    GUI.Label(new Rect((Screen.width - 460f) * 0.5f, Screen.height * 0.72f, 460f, 20f), _msg, style);
                }

                if (!active) return;

                int drawn = 0;
                if (_benches.Count > 0)
                {
                    for (int i = 0; i < _benches.Count; i++)
                    {
                        var e = _benches[i];
                        if (!e.OnMap) continue;
                        drawn++;

                        float x = e.Gui.x, y = e.Gui.y;
                        bool hot = (i == _hover) && !e.IsCurrent;

                        // 图标底衬
                        var boxRect = new Rect(x - 8f, y - 8f, 16f, 16f);
                        GUI.color = e.IsCurrent
                            ? new Color(0.55f, 0.55f, 0.55f, 0.85f)
                            : (hot ? new Color(1f, 0.85f, 0.25f, 0.98f) : new Color(0.35f, 0.85f, 1f, 0.9f));
                        GUI.DrawTexture(boxRect, Px);
                        GUI.color = Color.white;

                        // 边框
                        GUI.color = new Color(0f, 0f, 0f, 0.75f);
                        GUI.DrawTexture(new Rect(x - 9f, y - 9f, 18f, 1f), Px);
                        GUI.DrawTexture(new Rect(x - 9f, y + 8f, 18f, 1f), Px);
                        GUI.DrawTexture(new Rect(x - 9f, y - 9f, 1f, 18f), Px);
                        GUI.DrawTexture(new Rect(x + 8f, y - 9f, 1f, 18f), Px);
                        GUI.color = Color.white;

                        // 场景名
                        GUI.Label(new Rect(x - 60f, y + 9f, 120f, 15f), e.Scene, style);
                    }

                    // 悬停提示：光标有了之后，还得让玩家知道「这里能点」
                    if (_hover >= 0 && _hover < _benches.Count)
                    {
                        var hb = _benches[_hover];
                        GUI.Label(new Rect((Screen.width - 560f) * 0.5f, Screen.height - 54f, 560f, 22f),
                            "单击传送到  " + hb.Scene, style);
                    }
                }
                _drawnIcons = drawn;

                // 系统光标抢不回来时自己画一个（画在最上层，免得被图标盖住）。
                // 位置必须取 InputSystem 的鼠标坐标 —— 和点击判定同一套，保证「看到的」就是「点中的」。
                if (NeedSelfCursor)
                {
                    var m = UnityEngine.InputSystem.Mouse.current;
                    if (m != null)
                    {
                        Vector2 mp = m.position.ReadValue();
                        DrawCursor(mp.x, Screen.height - mp.y);
                    }
                }
            }
            catch (Exception e)
            {
                Bootstrap.Log("OnGUI failed: " + e);
            }
        }
    }
}
