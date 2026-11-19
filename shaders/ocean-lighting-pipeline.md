# 海面光影管线（架构说明）

本文是 `shaders/` 目录的设计依据：说明海面从几何到最终成像的完整光照链路、各阶段的输入输出与性能预算，以及它如何接入现有仓库。当前仓库（`apps/web` 为 React 19 + Vite 的水墨文字 UI，`packages/*` 为纯领域逻辑）**还没有实时 3D 渲染管线**，因此这里的 HLSL 以「参考实现 + 算法收敛」的形式先行落地：先把公式、矩阵约定、参数语义固定下来，后续按 WebGPU（WGSL）或原生 D3D12 通道平移，避免边写边改约定。

## 1. 目标与非目标

**目标**

- 近岸浅滩到深海的自然颜色过渡（吸收而非简单渐变贴图）
- 太阳/月亮在浪面上的碎光带（GGX 高光 + 波面斜率分布）
- 风浪下的泡沫带与岸边白浪，随浪高、水深变化
- 反射既有天空也反射近处船只/建筑，随视角 Fresnel 变化

**非目标（本期不做）**

- 离线渲染级别的 FFT 海浪（先做 Gerstner + FBM 混合）
- 体积云投射到水面的软阴影
- 水下全屏后处理（折射只做屏幕空间近似）

## 2. 阶段划分

| # | Pass | 分辨率 | 输入 | 输出 | 关键技术 |
|---|---|---|---|---|---|
| P0 | Depth Prepass | 全分辨率 | 场景不透明物 | `DepthRT`（`R32_FLOAT` 线性深度） | 只写深度，供折射/软边/SSR 使用 |
| P1 | Ocean Geometry | 全分辨率 | 网格 + 波参数 | `PositionWS` / `NormalWS` | Gerstner 4–6 波叠加 + FBM 细浪位移，法线取解析偏导 |
| P2 | Cascaded Shadow | 2048² × 2 级 | 太阳方向 | `ShadowRT` | CSM 2 级，3×3 PCF，`DepthBias` + 法线偏移抗阴影痤疮 |
| P3 | Planar Reflection | 半分辨率 | 镜像相机渲染（裁剪水下物） | `ReflectionRT`（`RGBA16_FLOAT`） | 镜像矩阵 + 屏幕空间扰动；SSR 作回退 |
| P4 | Refraction & Absorption | 半分辨率 | 场景色 copy + `DepthRT` | `RefractionRT` | 深度差决定折射偏移量；Beer–Lambert 吸收按水下光程积分 |
| P5 | Water Shading | 全分辨率 | P1–P4 结果 | HDR 颜色 | Fresnel 混合反射/折射 + GGX 太阳高光 + SSS 近似 + 泡沫 |
| P6 | Post | 全分辨率 | HDR 颜色 | LDR | Bloom（阈值 1.0）+ ACES 色调映射 + 抖动 |

P1 与 P2/P3 相互独立，可与主相机渲染并行提交；P4 必须在 P0 之后。

## 3. 着色方程

水面最终辐亮度按四个可加项组装，反射与折射之间用 Schlick 近似的 Fresnel 项配平：

```
L = F(θ) · L_reflect
  + (1 − F(θ)) · [ L_refract · exp(−σ_t · d) + L_sss ]
  + L_spec + L_foam

F(θ) = F0 + (1 − F0) · (1 − cos θ)^5        F0 = 0.02（纯水）
σ_t  = (σ_r + σ_g + σ_b)                    # 逐通道吸收系数，单位 1/米
```

- **反射**：平面反射 RT 按法线在屏幕空间的导数做 UV 扰动，强度随 `windSpeed` 上升；掠射角下退化为全反射，符合直觉。
- **折射/吸收**：以 `DepthRT` 与水面的深度差作为水下光程 `d`，逐通道衰减：红光最先消失，因此远岸呈青蓝。
- **太阳高光**：`D_GGX`（粗糙度随风速映射到 0.05–0.25）+ `V_SmithJoint` + `F_Schlick`，法线取波面斜率而不是几何法线，否则碎光带会糊成一片。
- **次表面**：屏幕空间背面深度差 × 波高 × 太阳方向，模拟浪尖透光（背光时的青绿色辉光）。
- **泡沫**：`saturate(waveHeight / foamThreshold)` 与浅水深度差取并集，加一层 FBM 噪声打碎边缘。

## 4. 参数

| 参数 | 类型 | 默认 | 语义 |
|---|---|---|---|
| `windDirection` | float2 | (1, 0) | 主浪传播方向（世界 XZ 平面，归一化） |
| `windSpeed` | float | 6.0 | 米/秒，同时驱动波幅、粗糙度与泡沫阈值 |
| `waveAmplitude` | float | 0.35 | Gerstner 叠加后总波高（米） |
| `choppiness` | float | 0.8 | 波峰尖锐度，0–1，过高会产生自交 |
| `waveLengths` | float4 | (48, 21, 9, 4) | 4 层 Gerstner 波长（米），逐层递减 |
| `absorption` | float3 | (0.45, 0.09, 0.06) | 逐通道吸收系数（1/米），蓝光衰减最慢 |
| `refractionStrength` | float | 0.02 | 折射 UV 偏移系数，按深度差缩放 |
| `foamThreshold` | float | 0.22 | 归一化波高阈值，低于该值的浪尖不出泡沫 |
| `specularRoughness` | float | 0.12 | 基础粗糙度，风速联动 ±0.13 |
| `sunDirection` | float3 | (0.3, 0.6, -0.7) | 指向太阳的归一化向量 |
| `sunIntensity` | float | 4.0 | 单位 lux 的压缩表示，HDR 线性空间 |
| `fogDensity` | float | 0.0015 | 指数雾密度（1/米），与 `Unlit.hlsl` 的 `FogParams.w` 同义 |

## 5. 资源与格式

| 名称 | 格式 | 尺寸 | 说明 |
|---|---|---|---|
| `DepthRT` | `R32_FLOAT` | 全分辨率 | 线性深度，不要 `D24S8` 直接采样 |
| `ReflectionRT` | `RGBA16_FLOAT` | 半分辨率 | 镜像相机结果，采样时双线性 |
| `RefractionRT` | `RGBA16_FLOAT` | 半分辨率 | 场景色降采样副本 |
| `ShadowRT` | `D32_FLOAT` | 2048² × 2 | 级联阴影贴图 |
| `HDRScene` | `RGBA16_FLOAT` | 全分辨率 | 着色与后处理输入，线性空间 |

所有颜色目标为线性空间，sRGB 转换只在最终 swapchain 上做一次，避免双重编码。

## 6. 性能预算

以 1920×1080 / 60 fps 为基准，水面相关 GPU 时间上限 **8 ms**：

- P3 反射与 P4 折射半分辨率（`ceil(w/2) × ceil(h/2)`），采样用双线性而不是全分辨率走样
- Gerstner 波层数上限 6，FBM 细浪只在 `distance < 200m` 时采样 3 层，远处降到 1 层
- 水面绘制 ≤ 3 个 draw call（近/远/泡沫），避免逐片元分支
- 阴影 3×3 PCF 固定循环，不用可变次数采样器
- 禁用 MSAA；边缘走 FXAA/TAA 后处理

## 7. 与仓库的接入点

- `shaders/` 只放**算法参考与常量约定**，不参与现有 TS 构建（不进入 `pnpm build`、不进 `turbo` 流水线），因此不会影响 `apps/web` 与 `packages/*` 的现有行为。
- `shaders/Unlit.hlsl` 是矩阵与颜色空间约定的基线：`mul(vector, matrix)` 行主序、线性空间、`SV_Position` 由 `ViewProjection` 提供。
- 后续落地顺序建议：先在独立 demo 工程里按本文件实现 P1/P5，跑通后再抽象成 `packages/render-ocean`（纯算法 + 参数校验），最后由 `apps/web` 的 canvas 层按需调用。
- 命名约定：`<Stage><Purpose>.hlsl`（如 `WaterShading.hlsl`、`OceanGeometry.hlsl`），着色器内常量统一 `camelCase`，CB 布局以 16 字节对齐。

## 8. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M0 | `Unlit.hlsl` 基线 + 本文 | 两个 entry point 均可编译（DXC / glslangValidator） |
| M1 | Gerstner 几何 + GGX 太阳高光 | 波面斜率驱动的碎光带，掠射角无拉伸 |
| M2 | 平面反射 + 深度吸收折射 | 近岸渐变自然，反射随视角 Fresnel 变化 |
| M3 | 泡沫 + SSS + 后处理 | 背光浪尖透光，岸边白浪不闪烁 |

## 9. 验证方式

```bash
# 需要 dxc 或 glslang（brew install glslang）
glslangValidator -D -V -S vert --hlsl-iomap -e VSMain -o /tmp/unlit.vs.spv shaders/Unlit.hlsl
glslangValidator -D -V -S frag --hlsl-iomap -e PSMain -o /tmp/unlit.ps.spv shaders/Unlit.hlsl
```

编译通过只能证明语法与接口正确；数值正确性仍需 GPU 抓帧（RenderDoc / Xcode Metal Capture）逐 pass 对照。
