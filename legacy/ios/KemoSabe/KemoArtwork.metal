#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Recover foreground colour from antialiased plum-matted edges. Use a local
// neighbour as the opaque reference so graphite and dark controls stay dark;
// treating every boundary as cream creates bright seams on coral props.
float4 keyedArtwork(SwiftUI::Layer layer, float2 at, float2 size, half4 pixel) {
    // Plates cut out ahead of time (scripts/key_artwork.py) have no backing to key.
    if (layer.sample(size*0.02).a < 0.5) return float4(float3(pixel.rgb)/max(float(pixel.a),0.0001), float(pixel.a));
    float3 key = float3(layer.sample(size*0.02).rgb);
    float3 rgb = float3(pixel.rgb)/max(float(pixel.a),0.0001);
    float distanceFromKey = distance(rgb,key);
    float reference = distanceFromKey;
    float closestToKey = distanceFromKey;
    // Two source pixels, but never less than half a point: at small sizes (the
    // 52 pt header avatar) the neighbours otherwise land on the same edge pixel,
    // no matte is removed, and a dark rim shows against light themes.
    float2 step = max(size/1254.0*2.0, float2(0.5));
    for (int x=-1;x<=1;x++) for(int y=-1;y<=1;y++) {
        half4 neighbour=layer.sample(at+float2(x,y)*step);
        float3 colour=float3(neighbour.rgb)/max(float(neighbour.a),0.0001);
        reference=max(reference,distance(colour,key));
        closestToKey=min(closestToKey,distance(colour,key));
    }
    float coverage=closestToKey<0.07 ? clamp(distanceFromKey/max(reference,0.001),0.0,1.0) : 1.0;
    float alpha=float(pixel.a)*smoothstep(0.035,0.10,distanceFromKey)*coverage;
    rgb=(rgb-key*(1.0-coverage))/max(coverage,0.001);
    return float4(clamp(rgb,0.0,1.0),alpha);
}

// Upper silhouette of the actual paper, not its rectangular bounding box.
// Solve the traced cubic by x so the warm paper never masks the tinted body.
float readingPaper(float2 p) {
    float x = 0.5-abs(p.x-0.5);
    float lo=0, hi=1;
    for (int i=0;i<12;i++) {
        float t=(lo+hi)*0.5, q=1-t;
        float bx=q*q*q*0.331+3*q*q*t*0.403+3*q*t*t*0.472+t*t*t*0.5;
        if (bx<x) lo=t; else hi=t;
    }
    float t=(lo+hi)*0.5,q=1-t;
    float top=q*q*q*0.634+3*q*q*t*0.643+3*q*t*t*0.657+t*t*t*0.701;
    return smoothstep(0.318,0.332,x)*smoothstep(top-0.001,top+0.001,p.y)
        *(1-smoothstep(0.712,0.715,p.y));
}

[[ stitchable ]] half4 kemoPlate(float2 position, SwiftUI::Layer layer,
    float2 size, float time, half4 bodyTint, half4 accentTint, float tintAmount,
    float4 flags, float4 expression) {
    float2 p = position / max(size, float2(1));
    if (flags.y > 0.5) {
        float mouth = 1.0-smoothstep(0.6,1.0,length((p-float2(0.5,0.584))/float2(0.062,0.04)));
        p.y = mix(p.y,0.584+(p.y-0.584)/(1.0+expression.z*0.65),mouth);
    }
    half4 pixel = layer.sample(p*size);
    if (flags.y > 0.5) {
        // Erase only the original painted eye, then sample the compressed eye
        // inside its own bounds. Never stretch the surrounding face UVs into
        // the plum background during a blink (the old resting-pose holes).
        float blink = clamp(max(flags.w,exp(-pow((fmod(time,5.8)-4.35)/0.075,2.0))),0.0,1.0);
        for (int i=0;i<2;i++) {
            float2 c=float2(i==0 ? 0.364 : 0.636,0.516);
            float region=1.0-smoothstep(0.88,1.0,length((p-c)/float2(0.066,0.095)));
            float paint=region;
            half4 left=layer.sample(float2(c.x-0.075,p.y)*size);
            half4 right=layer.sample(float2(c.x+0.075,p.y)*size);
            half4 skin=mix(left,right,half(clamp((p.x-c.x+0.075)/0.15,0.0,1.0)));
            pixel=mix(pixel,skin,half(paint));
            float2 source=p-expression.xy;
            source.y=c.y+(source.y-c.y)/max(0.07,1.0-blink*0.93);
            float eyeBounds=1.0-smoothstep(0.88,1.0,length((source-c)/float2(0.066,0.095)));
            if(eyeBounds>0) {
                half4 eye=layer.sample(source*size);
                float eyePaint=smoothstep(0.20,0.40,float(eye.r-eye.g))*eyeBounds;
                pixel=mix(pixel,eye,half(eyePaint));
            }
        }
    }
    float alpha = pixel.a;
    float3 rgb = float3(pixel.rgb)/max(alpha,0.0001);
    if(flags.x>0.5 && layer.sample(size*0.02).a > 0.5) {
        if (flags.x < 1.5) {
            float4 clean=keyedArtwork(layer,p*size,size,pixel);
            rgb=clean.rgb; alpha=clean.a;
        } else {
        float3 key = float3(layer.sample(size*0.02).rgb);
        alpha *= smoothstep(0.04,0.095,distance(rgb,key));
        if (flags.x > 1.5) {
            // Undo the plum matte in antialiased cream-paw boundary pixels.
            // Merely making the dark backing transparent leaves a dark rim.
            float coverage = clamp((rgb.r-key.r)/max(0.01,0.75-key.r),0.0,1.0);
            rgb = (rgb-key*(1.0-coverage))/max(coverage,0.001);
            alpha *= coverage;
        }
        }
    }
    float coral = smoothstep(0.25,0.43,rgb.r-rgb.g);
    float3 body = rgb*float3(bodyTint.rgb)/float3(0.965,0.91,0.82);
    float3 accent = float3(accentTint.rgb)*rgb.r/0.97;
    float paper = (flags.z > 0.5 && flags.z < 1.5 ? 1.0 : 0.0) * readingPaper(p)*(1.0-coral);
    // Props keep physical cream paper/cushions and dark displays. Only their
    // painted coral shell changes color; body recoloring remains character-only.
    rgb = flags.z > 1.5 ? mix(rgb,accent,tintAmount*coral)
                        : mix(rgb,mix(body,accent,coral),tintAmount*(1.0-paper));
    return half4(half3(clamp(rgb,0.0,1.0)*alpha),half(alpha));
}

float softRegion(float2 p, float2 center, float2 radius) {
    float d = length((p - center) / radius);
    return 1.0 - smoothstep(0.45, 1.0, d);
}

// Baked artwork with a deliberately small motion envelope. No dynamic relighting.
[[ stitchable ]] half4 kemoArtwork(float2 position, SwiftUI::Layer layer,
    float2 size, float time, half4 bodyTint, half4 accentTint, float tintAmount,
    float4 state, float2 attention) {
    float2 uv = position / max(size, float2(1.0));
    float writing = state.x, motion = state.y, speaking = state.z, thinking = state.w;
    float breath = sin(time * 1.65) * 0.004 * motion * (1.0 - writing);
    float perk = attention.x * 0.010;
    float2 p = uv;
    p.y = 0.9 + (p.y - 0.9) / (1.0 + breath + perk);
    p.x = 0.5 + (p.x - 0.5) / (1.0 - breath * 0.3);
    p.x += sin(time * 1.1) * 0.002 * thinking * motion;
    // Writing is a separate rigid-layer rig. Never warp or bob its source plate.
    if (writing < 0.5) {
        // Local eyelid compression: quick close, gentle release, uneven spacing.
        float cycle = fmod(time, 5.8);
        float blink = exp(-pow((cycle - 4.35) / 0.065, 2.0)) * motion;
        for (int eye = 0; eye < 2; ++eye) {
            float2 c = float2(eye == 0 ? 0.364 : 0.636, 0.516);
            float region = softRegion(p, c, float2(0.061, 0.083));
            p.y += (p.y - c.y) * blink * region * 3.8;
        }
        float mouth = softRegion(p, float2(0.5, 0.584), float2(0.062, 0.034));
        float syllable = (0.25 + 0.75 * abs(sin(time * 12.0))) * speaking * motion;
        p.y = mix(p.y, 0.584 + (p.y - 0.584) / (1.0 + syllable * 0.65), mouth);
    }
    half4 sample = layer.sample(p * size);
    float alpha = sample.a;
    float3 rgb = float3(sample.rgb) / max(alpha, 0.0001);
    if (writing > 0.5) {
        // Current plates are cut out at full resolution by scripts/key_artwork.py
        // (originals are in git history); keyedArtwork still keys a plum-backed plate.
        float4 clean=keyedArtwork(layer,p*size,size,sample);
        rgb=clean.rgb; alpha=clean.a;
    } else {
        // Trim subpixel matte fringe from the generated transparent source.
        float a = min(min(layer.sample(p * size + float2(0.7,0)).a, layer.sample(p * size - float2(0.7,0)).a),
                      min(layer.sample(p * size + float2(0,0.7)).a, layer.sample(p * size - float2(0,0.7)).a));
        alpha *= smoothstep(0.12, 0.80, a);
    }
    // Reserve accent recoloring for saturated paint, not the softly tinted blush.
    float coral = smoothstep(0.25, 0.43, rgb.r - rgb.g);
    float3 recoloredBody = rgb * float3(bodyTint.rgb) / float3(0.965, 0.91, 0.82);
    float light = max(rgb.r, 0.001) / 0.97;
    float3 recoloredAccent = float3(accentTint.rgb) * light;
    float3 recolored = mix(recoloredBody, recoloredAccent, coral);
    float x = clamp((p.x - 0.388) / 0.28, 0.0, 1.0);
    float paperTop = mix(0.741, 0.729, x), paperBottom = 0.812;
    // State 2 is the moving paw/pencil layer: it contains no paper.
    float paperLeft = mix(0.389,0.349,clamp((p.y-0.739)/0.059,0.0,1.0));
    float paper = (writing < 1.5 ? writing : 0.0) * smoothstep(paperLeft-0.002,paperLeft+0.002,p.x)
        * (1.0 - smoothstep(0.685,0.694,p.x));
    paper *= smoothstep(paperTop-0.002,paperTop+0.002,p.y) * (1.0 - smoothstep(paperBottom-0.002,paperBottom,p.y));
    // The right paw overlaps the page in the source; its cream pixels are fur,
    // not paper. Trace that curved occlusion instead of clipping at a rectangle.
    float pawEdge = 0.753 - 0.087*sqrt(max(0.0,1.0-pow((p.y-0.757)/0.072,2.0)));
    float holdingPaw = smoothstep(pawEdge-0.002,pawEdge+0.002,p.x)
        *smoothstep(0.701,0.708,p.y)*(1-smoothstep(0.845,0.853,p.y));
    paper *= (1.0-holdingPaw)*(1.0-coral);
    rgb = mix(rgb, recolored, tintAmount * (1.0 - paper));
    return half4(half3(clamp(rgb, 0.0, 1.0) * alpha), half(alpha));
}
