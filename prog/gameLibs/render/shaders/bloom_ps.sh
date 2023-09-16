include "shader_global.sh"
include "gbuffer.sh"
include "viewVecVS.sh"
//include "dacloud_mask.sh"
include "tonemapHelpers/use_full_tonemap_lut_inc.sh"

texture frame_tex;
texture blur_src_tex;

float4 blur_src_tex_size;
float4 blur_pixel_offset;
float4 bloom_upsample_params;

macro POSTFX()
  cull_mode=none;
  z_write=false;
  z_test=false;

  hlsl {
    struct VsOutput
    {
      VS_OUT_POSITION(pos)
      noperspective float2 tc : TEXCOORD0;
    };
  }
  
  USE_POSTFX_VERTEX_POSITIONS()
  hlsl(vs) {
    VsOutput postfx_vs(uint vertexId : SV_VertexID)
    {
      VsOutput output;
      float2 inpos = getPostfxVertexPositionById(vertexId);

      output.pos = float4(inpos,0,1);
      output.tc = screen_to_texcoords(inpos);
      return output;
    }
  }
  compile("target_vs", "postfx_vs");
endmacro

int should_write_log_lum = 1;
interval should_write_log_lum:off<1, on;

shader frame_bloom_downsample, bloom_downsample_hq, bloom_downsample_lq
{
  POSTFX()
  if (shader == frame_bloom_downsample)
  {
    (ps) { _tex0@smp2d = frame_tex; }
  } else
  {
    if (shader == bloom_downsample_hq)
    {
      (ps) {
        Exposure@buf = Exposure hlsl {
          StructuredBuffer<float> Exposure@buf;
        };
      }
      // do we use this on ios?
      if (should_write_log_lum == on && !hardware.metaliOS)
      {
        hlsl(ps) {
          #define WRITE_LOG_LUM 1
        }
      }
    }
    (ps) { _tex0@smp2d = blur_src_tex; }
  }
  (ps) { TexSize@f3 = blur_src_tex_size; }

  hlsl(ps) {
    float3 Box4(float3 p0, float3 p1, float3 p2, float3 p3)
    {
      return (p0 + p1 + p2 + p3) * 0.25f;
    }
    float GetLuminance(float3 v) {return dot(v, float3(0.212671, 0.715160, 0.072169));}
    struct MRT_OUTPUT
    {
      half3 bloomColor: SV_Target0;
    };
    #if WRITE_LOG_LUM
      RWTexture2D<half> lumaResult : register( u7 );
    #endif

    MRT_OUTPUT main(VsOutput IN HW_USE_SCREEN_POS)
    {
      float4 pos = GET_SCREEN_POS(IN.pos);
      MRT_OUTPUT ret;
      //#define THRESHOLD_TONEMAP(a) {float lum = GetLuminance(a); a = max(0, a-0.8); float w=1/(1+lum); a*=w; weight += w;}
      half3 tex2;

      ##if shader == frame_bloom_downsample
        const bool bKillFireflies = true;
        #define THRESHOLD(a)
      ##elif shader == bloom_downsample_hq
        const bool bKillFireflies = true;
        float ScaledThreshold = TexSize.z * Exposure[1];   // BloomThreshold / Exposure
        #if WRITE_LOG_LUM
          half luma = 0;
          //float farCorner = 0.25/4/4, farSide = 0.5/4/4, corner = 1.25/4/4, center = 2/4;
          //#define THRESHOLD(a) tex=pow2_vec3(tex*0.4);
          #define THRESHOLD(a) {tex2 = tex; tex = max(0, tex - ScaledThreshold);}
        #else
          #define THRESHOLD(a) {tex2 = tex; tex = max(0, tex - ScaledThreshold);}
        #endif
      ##else
        const bool bKillFireflies = false;
        #define THRESHOLD(a)
      ##endif

      #define addBlock(block) block+=tex

      //const float2 TexSize = 1 / (PS_ScreenSize.xy * 2);
      //const float2 TexSize = float2(StreakLength * InverseResolution.x, 1 * InverseResolution.y);

      half3 blockTL = 0, blockTR = 0, blockBR = 0, blockBL = 0;
      half3 tex;
      float2 tc = IN.tc;

      ##if shader != frame_bloom_downsample

      tex = tex2D(_tex0, tc.xy + float2(-2, -2) * TexSize.xy).rgb; THRESHOLD(farCorner);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockTL);
      
      tex = tex2D(_tex0, tc.xy + float2( 0, -2) * TexSize.xy).rgb; THRESHOLD(farSide);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockTL);addBlock(blockTR);
      
      tex = tex2D(_tex0, tc.xy + float2( 2, -2) * TexSize.xy).rgb; THRESHOLD(farCorner);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockTR);
      
      tex = tex2D(_tex0, tc.xy + float2(-2,  0) * TexSize.xy).rgb; THRESHOLD(farSide);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockTL);addBlock(blockBL);
      
      tex = tex2D(_tex0, tc.xy + float2( 0,  0) * TexSize.xy).rgb;
      #if WRITE_LOG_LUM
        luma += GetLuminance(tex);
      #endif
      THRESHOLD(center);

      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockTL);addBlock(blockTR);addBlock(blockBR);addBlock(blockBL);
      
      tex = tex2D(_tex0, tc.xy + float2( 2,  0) * TexSize.xy).rgb; THRESHOLD(farSide);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockTR);addBlock(blockBR);
      
      tex = tex2D(_tex0, tc.xy + float2(-2,  2) * TexSize.xy).rgb; THRESHOLD(farCorner);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockBL);
      
      tex = tex2D(_tex0, tc.xy + float2( 0,  2) * TexSize.xy).rgb; THRESHOLD(farSide);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockBL);addBlock(blockBR);
      
      tex = tex2D(_tex0, tc.xy + float2( 2,  2) * TexSize.xy).rgb; THRESHOLD(farCorner);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockBR);

      ##endif
      
      half3 blockCC = 0;
      tex = tex2D(_tex0, tc.xy + float2(-1, -1) * TexSize.xy).rgb; THRESHOLD(corner);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockCC);
      tex = tex2D(_tex0, tc.xy + float2( 1, -1) * TexSize.xy).rgb; THRESHOLD(corner);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockCC);
      tex = tex2D(_tex0, tc.xy + float2( 1,  1) * TexSize.xy).rgb; THRESHOLD(corner);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockCC);
      tex = tex2D(_tex0, tc.xy + float2(-1,  1) * TexSize.xy).rgb; THRESHOLD(corner);
      if (bKillFireflies) tex /= 1 + GetLuminance(tex);
      addBlock(blockCC);

      ##if shader != frame_bloom_downsample
      blockTL /= 4; blockTR /= 4; blockBR /= 4; blockBL /= 4; blockCC /= 4;
      
      if (bKillFireflies) 
      {
        // Convert back to uncompressed/linear range
        blockTL /= (1 - GetLuminance(blockTL));
        blockTR /= (1 - GetLuminance(blockTR));
        blockBR /= (1 - GetLuminance(blockBR));
        blockBL /= (1 - GetLuminance(blockBL));
        blockCC /= (1 - GetLuminance(blockCC));
      }
      ret.bloomColor = 0.5 * blockCC + 0.125 * (blockTL + blockTR + blockBR + blockBL);
      ##else
      blockCC = 0.25 * blockCC;
      if (bKillFireflies) 
        blockCC /= (1 - GetLuminance(blockCC));
      ret.bloomColor = blockCC;
      ##endif
      #if WRITE_LOG_LUM

        const float MinLog = Exposure[4];
        const float RcpLogRange = Exposure[7];
        //const float MinLog = -12;
        //const float RcpLogRange = 1./(4-MinLog);
        float logLuma = saturate((log2(luma) - MinLog) * RcpLogRange);  // Rescale to [0.0, 1.0]
        //LumaResult[DTid.xy] = logLuma * 254.0/255.0 + 1./255.0;                    // Rescale to [1, 255]
        //LumaResult[DTid.xy] = logLuma * 254.0/255.0 + 1.5/255.0;                    // Rescale to [1, 255]
        //LumaResult[DTid.xy] = luma * 254.0/255.0 + 1.5/255.0;
        float histPos = luma > 0 ? logLuma * 254.0/255.0 + 1./255.0 : 0;
        uint2 DTid = uint2(pos.xy);
        if ((DTid.x&3) == 1 && (DTid.y&3) == 1)//only write 1/4 of resolution in pixels
          lumaResult[DTid>>2] = histPos;
        //ret.bloomColor = 0;
      #endif
      return ret;
    }
  }

  compile("target_ps", "main");
}

shader bloom_upsample
{
  POSTFX()
  blend_src = bf; blend_dst = ibf;

  (ps) {
    _tex0@smp2d = blur_src_tex;
    params@f4 = bloom_upsample_params;
  }
  hlsl(ps) {

    half3 main(VsOutput IN HW_USE_SCREEN_POS): SV_Target0
    {
      float4 pos = GET_SCREEN_POS(IN.pos);
      float2 offset = params.xy;
      float2 texCoord = pos.xy*params.zw;//==

      float3 c0 = tex2D(_tex0, texCoord + float2(-1, -1) * offset).rgb;
      float3 c1 = tex2D(_tex0, texCoord + float2(0, -1) * offset).rgb;
      float3 c2 = tex2D(_tex0, texCoord + float2(1, -1) * offset).rgb;
      float3 c3 = tex2D(_tex0, texCoord + float2(-1, 0) * offset).rgb;
      float3 c4 = tex2D(_tex0, texCoord).rgb;
      float3 c5 = tex2D(_tex0, texCoord + float2(1, 0) * offset).rgb;
      float3 c6 = tex2D(_tex0, texCoord + float2(-1,1) * offset).rgb;
      float3 c7 = tex2D(_tex0, texCoord + float2(0, 1) * offset).rgb;
      float3 c8 = tex2D(_tex0, texCoord + float2(1, 1) * offset).rgb;

      //Tentfilter  0.0625f    
      return 0.0625f * (c0 + 2 * c1 + c2 + 2 * c3 + 4 * c4 + 2 * c5 + c6 + 2 * c7 + c8);
    }
  }

  compile("target_ps", "main");
}

shader bloom_blur_2, bloom_blur_3, bloom_blur_4
{
  supports none;
  supports global_frame;

  cull_mode=none;
  z_write=false;
  z_test=false;

  POSTFX_VS_TEXCOORD(0, tc)

  (ps) {
    src_tex@smp2d = blur_src_tex;
    pixel_offset@f2 = blur_pixel_offset;
  }
  hlsl(ps) {
    #define out_type float3

    out_type GaussianBlur( float2 centreUV, float2 pixelOffset )
    {
        out_type colOut = 0;

        ##if shader == bloom_blur_2
          #define stepCount 2
          float gWeights[stepCount]={0.450429,0.0495707};
          float gOffsets[stepCount]={0.53608,2.06049};
        ##elif shader == bloom_blur_3
          #define stepCount 3
          float gWeights[stepCount]={0.329654,0.157414,0.0129324};
          float gOffsets[stepCount]={0.622052,2.274,4.14755};
        ##elif shader == bloom_blur_4
          #define stepCount 4
          float gWeights[stepCount]={0.24956,0.192472,0.0515112,0.00645659};
          float gOffsets[stepCount]={0.644353,2.37891,4.2912,6.21672};
        ##endif

        UNROLL
        for( int i = 0; i < stepCount; i++ )
        {
          float2 texCoordOffset = gOffsets[i] * pixelOffset;
          out_type col = tex2Dlod( src_tex, float4(centreUV + texCoordOffset,0,0) ).rgb + tex2Dlod( src_tex, float4(centreUV - texCoordOffset,0,0) ).rgb;
          colOut += gWeights[i] * col;
        }
        return colOut;
        #undef stepCount
    }

    half3 main(VsOutput IN HW_USE_SCREEN_POS): SV_Target0
    {
      float4 pos = GET_SCREEN_POS(IN.pos);
      return GaussianBlur(IN.tc.xy, pixel_offset);
    }
  }

  compile("target_ps", "main");
}