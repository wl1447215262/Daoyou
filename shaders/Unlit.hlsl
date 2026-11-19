// shaders/Unlit.hlsl
//
// 最基础的 Unlit（无光照）模板，作为后续光影算法的基线参照。
// 只做四件事：顶点变换 → 贴图与颜色相乘 → 可选 Alpha 裁剪 → 可选距离雾。
// 不采样任何光照、阴影或环境贴图，输出颜色直接写入目标，便于对齐管线的
// 坐标系、矩阵约定与颜色空间。
//
// 约定：
//   * 行主序（row-major），向量左乘矩阵：mul(vector, matrix)
//   * 世界坐标右手系，+Y 向上；SV_Position 由 ViewProjection 给出
//   * 线性颜色空间，不做 sRGB 编解码；色调映射在后处理阶段统一处理
//   * 目标 profile：SM 6.0（DXC / glslangValidator -D）
//
// 编译：
//   dxc -T vs_6_0 -E VSMain shaders/Unlit.hlsl -Fo Unlit.vs.dxil
//   dxc -T ps_6_0 -E PSMain shaders/Unlit.hlsl -Fo Unlit.ps.dxil
//   glslangValidator -D -V -S vert --hlsl-iomap -e VSMain -o Unlit.vs.spv shaders/Unlit.hlsl
//   glslangValidator -D -V -S frag --hlsl-iomap -e PSMain -o Unlit.ps.spv shaders/Unlit.hlsl

#ifndef UNLIT_HLSL
#define UNLIT_HLSL

// ---------------------------------------------------------------------------
// 每帧常量：整帧只上传一次
// ---------------------------------------------------------------------------
cbuffer PerFrame : register(b0)
{
    float4x4 ViewProjection;   // 世界 → 裁剪空间
    float4   CameraPosition;   // xyz = 世界坐标相机位置，w = 保留
    float4   FogParams;        // rgb = 雾颜色（线性），w = 密度，单位 1/米
};

// ---------------------------------------------------------------------------
// 每物体常量：每个 draw call 一次
// ---------------------------------------------------------------------------
cbuffer PerObject : register(b1)
{
    float4x4 Model;            // 模型 → 世界
    float4   BaseColor;        // 顶点色/贴图的乘算 tint（线性）
    float    AlphaCutoff;      // 0 = 关闭裁剪；>0 时 alpha 低于该值丢弃片元
    float    FogEnabled;       // 0 = 关闭；非 0 = 启用距离雾
    float2   _UnlitPadding;    // 保持 16 字节对齐
};

// ---------------------------------------------------------------------------
// 资源
// ---------------------------------------------------------------------------
Texture2D    BaseMap     : register(t0);
SamplerState BaseSampler : register(s0);

// ---------------------------------------------------------------------------
// 输入 / 输出
// ---------------------------------------------------------------------------
struct VSInput
{
    float3 PositionOS : POSITION;
    float3 NormalOS   : NORMAL;      // Unlit 不使用，保留以共享顶点布局
    float2 UV         : TEXCOORD0;
    float4 Color      : COLOR;       // 顶点色，未使用时传 float4(1,1,1,1)
};

struct PSInput
{
    float4 PositionCS : SV_Position;
    float2 UV         : TEXCOORD0;
    float3 PositionWS : TEXCOORD1;
    float3 NormalWS   : TEXCOORD2;
    float4 Color      : COLOR;
};

// ---------------------------------------------------------------------------
// 顶点阶段
// ---------------------------------------------------------------------------
PSInput VSMain(VSInput input)
{
    PSInput output;

    float4 positionWS = mul(float4(input.PositionOS, 1.0), Model);
    output.PositionWS = positionWS.xyz;
    output.PositionCS = mul(positionWS, ViewProjection);

    // 法线只做方向变换，不做非均匀缩放的逆转置；Unlit 阶段不参与着色
    output.NormalWS = normalize(mul(float4(input.NormalOS, 0.0), Model).xyz);

    output.UV    = input.UV;
    output.Color = input.Color;
    return output;
}

// ---------------------------------------------------------------------------
// 像素阶段
// ---------------------------------------------------------------------------
float4 PSMain(PSInput input) : SV_Target
{
    float4 texel  = BaseMap.Sample(BaseSampler, input.UV);
    float4 albedo = texel * input.Color * BaseColor;

    if (AlphaCutoff > 0.0 && albedo.a < AlphaCutoff)
    {
        discard;
    }

    float3 color = albedo.rgb;

    if (FogEnabled > 0.0)
    {
        float distanceToCamera = distance(input.PositionWS, CameraPosition.xyz);
        // 指数雾：密度越大衰减越快，与距离无关的常量因子便于美术调参
        float fogFactor = 1.0 - exp(-max(distanceToCamera, 0.0) * FogParams.w);
        color = lerp(color, FogParams.rgb, saturate(fogFactor));
    }

    return float4(color, albedo.a);
}

#endif // UNLIT_HLSL
