/*
 * This file is part of MAME4iOS.
 *
 * Copyright (C) 2013 David Valdeita (Seleuco)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, see <http://www.gnu.org/licenses>.
 *
 * Linking MAME4iOS statically or dynamically with other modules is
 * making a combined work based on MAME4iOS. Thus, the terms and
 * conditions of the GNU General Public License cover the whole
 * combination.
 *
 * In addition, as a special exception, the copyright holders of MAME4iOS
 * give you permission to combine MAME4iOS with free software programs
 * or libraries that are released under the GNU LGPL and with code included
 * in the standard release of MAME under the MAME License (or modified
 * versions of such code, with unchanged license). You may copy and
 * distribute such a system following the terms of the GNU GPL for MAME4iOS
 * and the licenses of the other code concerned, provided that you include
 * the source code of that other code when and as the GNU GPL requires
 * distribution of source code.
 *
 * Note that people who make modified versions of MAME4iOS are not
 * obligated to grant this special exception for their modified versions; it
 * is their choice whether to do so. The GNU General Public License
 * gives permission to release a modified version without this exception;
 * this exception also makes it possible to release a modified version
 * which carries forward this exception.
 *
 * MAME4iOS is dual-licensed: Alternatively, you can license MAME4iOS
 * under a MAME license, as set out in http://mamedev.org/
 */
#import <Metal/Metal.h>
#import "CGScreenView.h"        // for colorspace helper.
#import "MetalScreenView.h"
#import "myosd.h"

#define DebugLog 0
#if DebugLog == 0
#define NSLog(...) (void)0
#endif

#pragma mark - TIMERS

//#define WANT_TIMERS
#import "Timer.h"

TIMER_INIT_BEGIN
TIMER_INIT(draw_screen)
TIMER_INIT(texture_load)
TIMER_INIT(texture_load_pal16)
TIMER_INIT(texture_load_rgb32)
TIMER_INIT(texture_load_rgb15)
TIMER_INIT_END

#pragma mark - MetalScreenView

@implementation MetalScreenView {
    NSDictionary* _options;
    MTLSamplerMinMagFilter _filter;
    Shader _screen_shader;
    Shader _line_shader;
    CGFloat _line_width_scale;
    NSString* _line_width_scale_variable;
}

#pragma mark - SCREEN SHADER and LINE SHADER Options

// SCREEN SHADER
//
// Metal shader string is of the form:
//        <Friendly Name> : <shader description>
//
// NOTE: see MetalView.h for what a <shader description> is.
// in addition to the <shader description> in MetalView.h you can specify a named variable like so....
//
//       variable_name = <default value> <min value> <max value> <step value>
//
//  you dont use commas to separate values, use spaces.
//  min, max, and step are all optional, and only effect the InfoHUD, MetalView ignores them.
//
//  the following variables are pre-defined by MetalView and MetalScreenView
//
//      frame-count             - current frame number, this will reset to zero from time to time (like on resize)
//      render-target-size      - size of the render target (in pixels)
//      mame-screen-dst-rect    - the size (in pixels) of the output quad
//      mame-screen-src-rect    - the size (in pixels) of the input SCREEN texture
//      mame-screen-size        - the size (in pixels) of the input SCREEN texture
//      mame-screen-matrix      - matrix to convert texture coordinates (u,v) to crt (x,scanline)
//
//  Presets are simply the @string without the key names, only numbers!
//
+ (NSArray*)screenShaderList {
    return @[kScreenViewShaderDefault,
             @"simpleTron: simpleCRT, mame-screen-dst-rect, mame-screen-src-rect,\
                            Vertical Curvature = 5.0 1.0 10.0 0.1,\
                            Horizontal Curvature = 4.0 1.0 10.0 0.1,\
                            Curvature Strength = 0.25 0.0 1.0 0.05,\
                            Light Boost = 1.3 0.1 3.0 0.1, \
                            Vignette Strength = 0.05 0.0 1.0 0.05,\
                            Zoom Factor = 1.0 0.01 5.0 0.1",
             @"megaTron : megaTron, mame-screen-src-rect, mame-screen-dst-rect,\
                            Shadow Mask Type = 3.0 0.0 3.0 1.0,\
                            Shadow Mask Intensity = 0.5 0.0 1.0 0.05,\
                            Scanline Thinness = 0.7 0.0 1.0 0.05,\
                            Horizontal Scanline Blur = 1.8 1.0 10.0 0.05,\
                            CRT Curvature = 0.02 0.0 0.25 0.01,\
                            Use Trinitron-style Curvature = 0.0 0.0 1.0 1.0,\
                            CRT Corner Roundness = 3.0 2.0 11.0 1.0,\
                            CRT Gamma = 2.9 0.0 5.0 0.1",
             @"megaTron - Shadow Mask Strong: megaTron, mame-screen-src-rect, mame-screen-dst-rect,3.0,0.75,0.6,1.4,0.02,1.0,2.0,3.0",
             @"megaTron - Vertical Games (Use Linear Filter): megaTron, mame-screen-src-rect, mame-screen-dst-rect,3.0,0.4,0.8,3.0,0.02,0.0,3.0,2.9",
             @"megaTron - Grille Mask: megaTron, mame-screen-src-rect, mame-screen-dst-rect,2.0,0.85,0.6,2.0,0.02,1.0,2.0,3.0",
             @"megaTron - Grille Mask Lite: megaTron, mame-screen-src-rect, mame-screen-dst-rect,1.0,0.6,0.6,1.6,0.02,1.0,2.0,2.8",
             @"megaTron - No Shadow Mask but Blurred: megaTron, mame-screen-src-rect, mame-screen-dst-rect,0.0,0.6,0.6,1.0,0.02,0.0,2.0,2.6",
             
             @"ulTron : ulTron, mame-screen-src-rect, mame-screen-dst-rect",
             
#ifdef DEBUG
             @"Wombat1: mame_screen_test, mame-screen-size, frame-count, 1.0, 8.0, 8.0",
             @"Wombat2: mame_screen_test, mame-screen-size, frame-count, wombat_rate=2.0, wombat_u=16.0, wombat_v=16.0",
             @"Test (dot): mame_screen_dot, mame-screen-matrix",
             @"Test (scanline): mame_screen_line, mame-screen-matrix",
             @"Test (rainbow): mame_screen_rainbow, mame-screen-matrix, frame-count, rainbow_h = 16.0 4.0 32.0 1.0, rainbow_speed = 1.0 1.0 16.0",
#endif
    ];
}

// LINE SHADER - a line shader is exactly like a screen shader.
//
// **EXCEPT** the first parameter of a line-shader is assumed to be the `line-width-scale`
//
// all line widths will be multiplied by `line-width-scale` before being converted to triangles
//
// when the line fragment shader is called, the following is set:
//
//      color.a is itterated from 1.0 on center line to 0.25 on the line edge.
//      texture.x is itterated along the length of the line 0 ... length (the length is in model cordinates)
//      texture.y is itterated along the width of the line, -1 .. +1, with 0 being the center line
//
//  the default line shader just uses the passed color and a blend mode of ADD.
//  so the default line shader depends on the color.a being ramped down to 0.25x and color.rgb being the line color.
//
// TODO: MAME draws all lines with a alpha value, maybe we should pre-multiply and pass color to the shader with color.a = 1?
//
+ (NSArray*)lineShaderList {
    return @[kScreenViewShaderDefault,
        @"lineTron: lineTron, blend=add, width-scale=1.5 1 4, frame-count, falloff=2 1 4",

#ifdef DEBUG
        @"Dash: mame_test_vector_dash, blend=add, width-scale=1.0 0.25 6.0, frame-count, length=25.0, speed=16.0",
        @"Dash (Fast): mame_test_vector_dash, blend=add, 1.0, frame-count, 15.0, 16.0",
        @"Dash (Slow): mame_test_vector_dash, blend=add, 1.0, frame-count, 15.0, 2.0",
                 
        @"Pulse: mame_test_vector_pulse, blend=add, width-scale=1.0 0.25 6.0, frame-count, rate=2.0",
        @"Pulse (Fast): mame_test_vector_pulse, blend=add, 1.0, frame-count, 0.5",
        @"Pulse (Slow): mame_test_vector_pulse, blend=add, 1.0, frame-count, 2.0",
#endif
    ];
}
+ (NSArray*)filterList {
    return @[kScreenViewFilterNearest,kScreenViewFilterLinear];
}
+ (NSArray*)colorSpaceList {
    return [CGScreenView colorSpaceList];
}

#pragma mark - MetalScreenView INIT

// split and trim a string
// TODO: move this to a common place??
static NSMutableArray* split(NSString* str, NSString* sep) {
    NSMutableArray* arr = [[str componentsSeparatedByString:sep] mutableCopy];
    for (int i=0; i<arr.count; i++)
        arr[i] = [arr[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return arr;
}

- (void)setOptions:(NSDictionary *)options {
    _options = options;
    
    // set our framerate
    self.preferredFramesPerSecond = 60;
    
    // set a custom color space
    NSString* color_space = _options[kScreenViewColorSpace];

    if (color_space != nil)
    {
        CGColorSpaceRef colorSpace = [CGScreenView createColorSpaceFromString:color_space];
        [(id)self.layer setColorspace:colorSpace];
        CGColorSpaceRelease(colorSpace);
    }
    
    // enable filtering
    NSString* filter_string = _options[kScreenViewFilter];
    
    if ([filter_string isEqualToString:kScreenViewFilterLinear])
        _filter = MTLSamplerMinMagFilterLinear;
    else
        _filter = MTLSamplerMinMagFilterNearest;
    
    // get the shader to use when drawing the SCREEN, default to the plain Texture COPY shader if not specified.
    _screen_shader = _options[kScreenViewScreenShader] ?: kScreenViewShaderDefault;
    
    if ([_screen_shader length] == 0 || [_screen_shader isEqualToString:kScreenViewShaderDefault] || [_screen_shader isEqualToString:kScreenViewShaderNone])
        _screen_shader = ShaderTexture;
    
    // get the shader to use when drawing VECTOR lines, default to the ADD shader if not specified.
    _line_shader = _options[kScreenViewLineShader] ?: kScreenViewShaderDefault;
    
    if ([_line_shader length] == 0 || [_line_shader isEqualToString:kScreenViewShaderDefault] || [_line_shader isEqualToString:kScreenViewShaderNone])
        _line_shader = ShaderAdd;
    
    // parse the first param of the line shader to get the line width scale factor.
    // NOTE the first param can be a variable or a contant, support variables for the HUD.
    _line_width_scale = 1.0;
    _line_width_scale_variable = nil;
    NSArray* arr = split(_line_shader, @",");
    NSUInteger idx = 1; // skip first component that is the shader name.
    if (idx < arr.count && [arr[idx] hasPrefix:@"blend="])
        idx++;
    if (idx < arr.count && [arr[idx] floatValue] != 0.0)
        _line_width_scale = [arr[idx] floatValue];
    else if (idx < arr.count)
        _line_width_scale_variable = split(arr[idx],@"=").firstObject;
    
    NSLog(@"FILTER: %@", _filter == MTLSamplerMinMagFilterNearest ? @"NEAREST" : @"LINEAR");
    NSLog(@"SCREEN SHADER: %@", _screen_shader);
    NSLog(@"LINE SHADER: %@", _line_shader);
    if (_line_width_scale_variable != nil)
        NSLog(@"    width-scale: %@", _line_width_scale_variable);
    else
        NSLog(@"    width-scale: %0.3f", _line_width_scale);

    [self setNeedsLayout];
}

#pragma mark - MetalScreenView UIView stuff

- (void)layoutSubviews {
    [super layoutSubviews];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
}
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
}

#pragma mark - texture conversion

static void texture_load(void* data, id<MTLTexture> texture) {
    
    myosd_render_primitive* prim = (myosd_render_primitive*)data;
    NSUInteger width = texture.width;
    NSUInteger height = texture.height;
    
    static char* texture_format_name[] = {"UNDEFINED", "PAL16", "PALA16", "555", "RGB", "ARGB", "YUV16"};
    texture.label = [NSString stringWithFormat:@"MAME %08lX:%d %dx%d %s", (NSUInteger)prim->texture_base, prim->texture_seqid, prim->texture_width, prim->texture_height, texture_format_name[prim->texformat]];

    TIMER_START(texture_load)

    switch (prim->texformat) {
        case TEXFORMAT_RGB15:
        {
            TIMER_START(texture_load_rgb15)
            if (prim->texture_palette == NULL) {
                [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:prim->texture_base bytesPerRow:prim->texture_rowpixels*2];
            }
            else {
                uint16_t* src = prim->texture_base;
                uint16_t* dst = (uint16_t*)myosd_screen;
                const uint32_t* pal = prim->texture_palette;
                for (NSUInteger y=0; y<height; y++) {
                    for (NSUInteger x=0; x<width; x++) {
                        uint16_t u16 = *src++;
                        *dst++ = ((pal[(u16 >>  0) & 0x1F]       ) >> 3) |
                                 ((pal[(u16 >>  5) & 0x1F] & 0xF8) << 2) |
                                 ((pal[(u16 >> 10) & 0x1F] & 0xF8) << 7) |
                                 0x8000;
                    }
                    src += prim->texture_rowpixels - width;
                }
                [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:myosd_screen bytesPerRow:width*2];
            }
            TIMER_STOP(texture_load_rgb15)
            break;
        }
        case TEXFORMAT_RGB32:
        case TEXFORMAT_ARGB32:
        {
            TIMER_START(texture_load_rgb32)
            if (prim->texture_palette == NULL) {
                [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:prim->texture_base bytesPerRow:prim->texture_rowpixels*4];
            }
            else {
                uint32_t* src = prim->texture_base;
                uint32_t* dst = (uint32_t*)myosd_screen;
                const uint32_t* pal = prim->texture_palette;
                for (NSUInteger y=0; y<height; y++) {
                    for (NSUInteger x=0; x<width; x++) {
                        uint32_t rgba = *src++;
                        *dst++ = (pal[(rgba >>  0) & 0xFF] <<  0) |
                                 (pal[(rgba >>  8) & 0xFF] <<  8) |
                                 (pal[(rgba >> 16) & 0xFF] << 16) |
                                 (pal[(rgba >> 24) & 0xFF] << 24) ;
                    }
                    src += prim->texture_rowpixels - width;
                }
                [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:myosd_screen bytesPerRow:width*4];
            }
            TIMER_STOP(texture_load_rgb32)
            break;
        }
        case TEXFORMAT_PALETTE16:
        case TEXFORMAT_PALETTEA16:
        {
            TIMER_START(texture_load_pal16)
            uint16_t* src = prim->texture_base;
            uint32_t* dst = (uint32_t*)myosd_screen;
            const uint32_t* pal = prim->texture_palette;
            for (NSUInteger y=0; y<height; y++) {
                NSUInteger dx = width;
                if ((intptr_t)dst % 8 == 0) {
                    while (dx >= 4) {
                        uint64_t u64 = *(uint64_t*)src;
                        ((uint64_t*)dst)[0] = ((uint64_t)pal[(u64 >>  0) & 0xFFFF]) | (((uint64_t)pal[(u64 >> 16) & 0xFFFF]) << 32);
                        ((uint64_t*)dst)[1] = ((uint64_t)pal[(u64 >> 32) & 0xFFFF]) | (((uint64_t)pal[(u64 >> 48) & 0xFFFF]) << 32);
                        dst += 4; src += 4; dx -= 4;
                    }
                    if (dx >= 2) {
                        uint32_t u32 = *(uint32_t*)src;
                        ((uint64_t*)dst)[0] = ((uint64_t)pal[(u32 >>  0) & 0xFFFF]) | (((uint64_t)pal[(u32 >> 16) & 0xFFFF]) << 32);
                        dst += 2; src += 2; dx -= 2;
                    }
                }
                while (dx-- > 0)
                    *dst++ = pal[*src++];
                src += prim->texture_rowpixels - width;
            }
            TIMER_STOP(texture_load_pal16)
            [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:myosd_screen bytesPerRow:width*4];
            break;
        }
        case TEXFORMAT_YUY16:
        {
            // this texture format is only used for AVI files and LaserDisc player!
            assert(FALSE);
            break;
        }
        default:
            assert(FALSE);
            break;
    }
    TIMER_STOP(texture_load)
}

#pragma mark - draw MAME primitives

// return 1 if you handled the draw, 0 for a software render
// NOTE this is called on MAME background thread, dont do anything stupid.
- (int)drawScreen:(void*)prim_list {
    static Shader shader_map[] = {ShaderNone, ShaderAlpha, ShaderMultiply, ShaderAdd};
    static Shader shader_tex_map[]  = {ShaderTexture, ShaderTextureAlpha, ShaderTextureMultiply, ShaderTextureAdd};

#ifdef DEBUG
    [self drawScreenDebug:prim_list];
#endif
    
#if 0
    // before calling draw-begin do a pass and load all textures.
    for (myosd_render_primitive* prim = prim_list; prim != NULL; prim = prim->next) {
        if (prim->type == RENDER_PRIMITIVE_QUAD && prim->texture_base != NULL) {
            // set the texture
            [self loadTexture:prim->texture_base hash:prim->texture_seqid
                       width:prim->texture_width height:prim->texture_height
                      format:(prim->texformat == TEXFORMAT_RGB15 ? MTLPixelFormatBGR5A1Unorm : MTLPixelFormatBGRA8Unorm)
                texture_load:texture_load texture_load_data:prim];
        }
    }
#endif

    if (![self drawBegin]) {
        NSLog(@"drawBegin *FAIL* dropping frame on the floor.");
        return 1;
    }
    NSTimeInterval time = CACurrentMediaTime();
    TIMER_START(draw_screen)

    NSUInteger num_screens = 0;
    
    [self setViewRect:CGRectMake(0, 0, myosd_video_width, myosd_video_height)];
    
    CGFloat scale_x = self.drawableSize.width  / myosd_video_width;
    CGFloat scale_y = self.drawableSize.height / myosd_video_height;
    CGFloat scale   = MIN(scale_x, scale_y);
    
    // get the line width scale for this frame, if it is variable.
    if (_line_width_scale_variable != nil) {
        NSValue* val = [self getShaderVariables][_line_width_scale_variable];
        if (val != nil && [val isKindOfClass:[NSNumber class]])
            _line_width_scale = [(NSNumber*)val floatValue];
    }

    // walk the primitive list and render
    for (myosd_render_primitive* prim = prim_list; prim != NULL; prim = prim->next) {
        
        VertexColor color = VertexColor(prim->color_r, prim->color_g, prim->color_b, prim->color_a);
        
        CGRect rect = CGRectMake(floor(prim->bounds_x0 + 0.5),  floor(prim->bounds_y0 + 0.5),
                                 floor(prim->bounds_x1 + 0.5) - floor(prim->bounds_x0 + 0.5),
                                 floor(prim->bounds_y1 + 0.5) - floor(prim->bounds_y0 + 0.5));

        if (prim->type == RENDER_PRIMITIVE_QUAD && prim->texture_base != NULL) {
            
            // set the texture
            [self setTexture:0 texture:prim->texture_base hash:prim->texture_seqid
                       width:prim->texture_width height:prim->texture_height
                      format:(prim->texformat == TEXFORMAT_RGB15 ? MTLPixelFormatBGR5A1Unorm : MTLPixelFormatBGRA8Unorm)
                texture_load:texture_load texture_load_data:prim];

            // set the shader
            if (prim->screentex) {
                // render of the game screen, use a custom shader
                // set the following shader variables so the shader knows the pixel size of a scanline etc....
                //
                //      mame-screen-dst-rect - the size (in pixels) of the output quad
                //      mame-screen-src-rect - the size (in pixels) of the input texture
                //      mame-screen-size     - the size (in pixels) of the input texture
                //      mame-screen-matrix   - matrix to convert texture coordinates (u,v) to crt (x,scanline)
                //
                CGSize src_size = CGSizeMake((prim->texorient & ORIENTATION_SWAP_XY) ? prim->texture_height : prim->texture_width,
                                             (prim->texorient & ORIENTATION_SWAP_XY) ? prim->texture_width : prim->texture_height);
                
                CGRect src_rect = CGRectMake(0, 0, src_size.width, src_size.height);
                CGRect dst_rect = CGRectMake(rect.origin.x * scale_x, rect.origin.y * scale_y, rect.size.width * scale_x, rect.size.height * scale_y);
                
                // create a matrix to convert texture coordinates (u,v) to crt scanlines (x,y)
                simd_float2x2 mame_screen_matrix;
                if (prim->texorient & ORIENTATION_SWAP_XY)
                    mame_screen_matrix = (matrix_float2x2){{ {0,prim->texture_width}, {prim->texture_height,0} }};
                else
                    mame_screen_matrix = (matrix_float2x2){{ {prim->texture_width,0}, {0,prim->texture_height} }};
                
                [self setShaderVariables:@{
                    @"mame-screen-dst-rect" :@(dst_rect),
                    @"mame-screen-src-rect" :@(src_rect),
                    @"mame-screen-size"     :@(src_size),
                    @"mame-screen-matrix"   :[NSValue value:&mame_screen_matrix withObjCType:@encode(float[2][2])],
                }];
                [self setTextureFilter:_filter];
                [self setShader:_screen_shader];
                num_screens++;
            }
            else {
                // render of artwork (or mame text). use normal shader with no filtering
                [self setTextureFilter:MTLSamplerMinMagFilterNearest];
                [self setShader:shader_tex_map[prim->blendmode]];
            }
            
            // set the address mode.
            if (prim->texwrap)
                [self setTextureAddressMode:MTLSamplerAddressModeRepeat];
            else
                [self setTextureAddressMode:MTLSamplerAddressModeClampToZero];

            // draw a quad in the correct orientation
            UIImageOrientation orientation = UIImageOrientationUp;
            if (prim->texorient == ORIENTATION_ROT90)
                orientation = UIImageOrientationRight;
            else if (prim->texorient == ORIENTATION_ROT180)
                orientation = UIImageOrientationDown;
            else if (prim->texorient == ORIENTATION_ROT270)
                orientation = UIImageOrientationLeft;

            [self drawRect:rect color:color orientation:orientation];
        }
        else if (prim->type == RENDER_PRIMITIVE_QUAD) {
            // solid color quad. only ALPHA or NONE blend mode.
            
            if (prim->blendmode == BLENDMODE_ALPHA && prim->color_a != 1.0)
                [self setShader:ShaderAlpha];
            else
                [self setShader:ShaderNone];

            [self drawRect:rect color:color];
        }
        else if (prim->type == RENDER_PRIMITIVE_LINE && (prim->width * scale) <= 1.0) {
            // single pixel line.
            [self setShader:shader_map[prim->blendmode]];
            [self drawLine:CGPointMake(prim->bounds_x0, prim->bounds_y0) to:CGPointMake(prim->bounds_x1, prim->bounds_y1) color:color];
        }
        else if (prim->type == RENDER_PRIMITIVE_LINE) {
            // wide line, if the blendmode is ADD this is a VECTOR line, else a UI line.
            if (prim->blendmode == BLENDMODE_ADD) {
                // this line is a vector line, use a special shader
                
                // pre-multiply color, so shader had non-iterated color
                color = color * simd_make_float4(color.a, color.a, color.a, 1/color.a);
                [self setShader:_line_shader];
                [self drawLine:CGPointMake(prim->bounds_x0, prim->bounds_y0) to:CGPointMake(prim->bounds_x1, prim->bounds_y1) width:(prim->width * _line_width_scale) color:color];
            }
            else {
                // this line is from MAME UI, draw normal
                [self setShader:shader_map[prim->blendmode]];
                [self drawLine:CGPointMake(prim->bounds_x0, prim->bounds_y0) to:CGPointMake(prim->bounds_x1, prim->bounds_y1) width:prim->width color:color];
            }
        }
        else {
            NSLog(@"Unknown RENDER_PRIMITIVE!");
            assert(FALSE);  // bad primitive
        }
    }
    
#if 0
    // walk the primitive list and draw wire frame
    for (myosd_render_primitive* prim = prim_list; prim != NULL; prim = prim->next) {
        
        VertexColor color = VertexColor(0, 1, 0, 1);
        [self setShader:ShaderNone];

        [self drawLine:CGPointMake(prim->bounds_x0, prim->bounds_y0) to:CGPointMake(prim->bounds_x1, prim->bounds_y0) color:color];
        [self drawLine:CGPointMake(prim->bounds_x1, prim->bounds_y0) to:CGPointMake(prim->bounds_x1, prim->bounds_y1) color:color];
        [self drawLine:CGPointMake(prim->bounds_x1, prim->bounds_y1) to:CGPointMake(prim->bounds_x0, prim->bounds_y1) color:color];
        [self drawLine:CGPointMake(prim->bounds_x0, prim->bounds_y1) to:CGPointMake(prim->bounds_x0, prim->bounds_y0) color:color];
        [self drawLine:CGPointMake(prim->bounds_x0, prim->bounds_y0) to:CGPointMake(prim->bounds_x1, prim->bounds_y1) color:color];
    }
#endif
    
    [self drawEnd];
    TIMER_STOP(draw_screen)
    
    if (TIMER_COUNT(draw_screen) % 100 == 0) {
        TIMER_DUMP();
        TIMER_RESET();
    }
    
    time = CACurrentMediaTime() - time;

    // dont starve other threads, MAME does not like to sleep, let Metal and Audio do some work.
    if (time < 0.005)
        usleep((0.005 - time) * 1000000.0);
    
    // set the number of SCREENs we rendered, so the app can detect RASTER vs VECTOR game.
    _numScreens = num_screens;

    // always return 1 saying we handled the draw.
    return 1;
}

#pragma mark - CODE COVERAGE and DEBUG stuff

#ifdef DEBUG
//
// CODE COVERAGE - this is where we track what types of primitives MAME has given us.
//                 run the app in the debugger, and if you stop in this function, you
//                 have seen a primitive or texture format that needs verified, verify
//                 that the game runs and looks right, then check off that things worked
//
// LINES
//      [X] width <= 1.0                MAME menu
//      [X] width  > 1.0                dkong artwork
//      [ ] antialias <= 1.0
//      [X] antialias  > 1.0            asteroid
//      [ ] blend mode NONE
//      [X] blend mode ALPHA            MAME menu
//      [ ] blend mode MULTIPLY
//      [X] blend mode ADD              asteroid
//
// QUADS
//      [X] blend mode NONE             MAME menu
//      [X] blend mode ALPHA            MAME menu
//      [X] blend mode MULTIPLY         N/A
//      [X] blend mode ADD              N/A
//
// TEXTURED QUADS
//      [X] blend mode NONE
//      [X] blend mode ALPHA            MAME menu (text)
//      [X] blend mode MULTIPLY         bzone
//      [X] blend mode ADD              dkong artwork
//      [X] rotate 0                    MAME menu (text)
//      [X] rotate 90                   pacman
//      [X] rotate 180                  mario, cocktail
//      [X] rotate 270                  mario, cocktail.
//      [X] texture WRAP                MAME menu
//      [X] texture CLAMP               MAME menu
//
// TEXTURE FORMATS
//      [X] PALETTE16                   pacman
//      [ ] PALETTEA16
//      [X] RGB15                       megaplay, streets of rage II
//      [X] RGB32                       neogeo
//      [X] ARGB32                      MAME menu (text)
//      [-] YUY16                       N/A
//      [X] RGB15 with PALETTE          megaplay
//      [X] RGB32 with PALETTE          neogeo
//      [-] ARGB32 with PALETTE         N/A
//      [-] YUY16 with PALETTE          N/A
//
- (void)drawScreenDebug:(void*)prim_list {
    
    for (myosd_render_primitive* prim = prim_list; prim != NULL; prim = prim->next) {
        
        assert(prim->type == RENDER_PRIMITIVE_LINE || prim->type == RENDER_PRIMITIVE_QUAD);
        assert(prim->blendmode <= BLENDMODE_ADD);
        assert(prim->texformat <= TEXFORMAT_YUY16);
        assert(prim->texture_base == NULL || prim->texformat != TEXFORMAT_UNDEFINED);
        assert(prim->unused == 0);

        float width = prim->width;
        int blend = prim->blendmode;
        int fmt = prim->texformat;
        int aa = prim->antialias;
        int orient = prim->texorient;
        int wrap = prim->texwrap;

        if (prim->type == RENDER_PRIMITIVE_LINE) {
            if (width <= 1.0 && !aa)
                assert(TRUE);
            if (width  > 1.0 && !aa)
                assert(TRUE);
            if (width <= 1.0 && aa)
                assert(FALSE);
            if (width  > 1.0 && aa)
                assert(TRUE);
            if (blend == BLENDMODE_NONE)
                assert(FALSE);
            if (blend == BLENDMODE_ALPHA)
                assert(TRUE);
            if (blend == BLENDMODE_RGB_MULTIPLY)
                assert(FALSE);
            if (blend == BLENDMODE_ADD)
                assert(TRUE);
        }
        else if (prim->type == RENDER_PRIMITIVE_QUAD && prim->texture_base == NULL) {
            if (blend == BLENDMODE_NONE)
                assert(TRUE);
            if (blend == BLENDMODE_ALPHA)
                assert(TRUE);
            if (blend == BLENDMODE_RGB_MULTIPLY)
                assert(TRUE);
            if (blend == BLENDMODE_ADD)
                assert(TRUE);
        }
        else if (prim->type == RENDER_PRIMITIVE_QUAD) {
            if (blend == BLENDMODE_NONE)
                assert(TRUE);
            if (blend == BLENDMODE_ALPHA)
                assert(TRUE);
            if (blend == BLENDMODE_RGB_MULTIPLY)
                assert(TRUE);
            if (blend == BLENDMODE_ADD)
                assert(TRUE);
            
            if (orient == ORIENTATION_ROT0)
                assert(TRUE);
            if (orient == ORIENTATION_ROT90)
                assert(TRUE);
            if (orient == ORIENTATION_ROT180)
                assert(TRUE);
            if (orient == ORIENTATION_ROT270)
                assert(TRUE);
            
            if (wrap == 0)
                assert(TRUE);
            if (wrap == 1)
                assert(TRUE);

            if (fmt == TEXFORMAT_RGB15 && prim->texture_palette == NULL)
                assert(TRUE);
            if (fmt == TEXFORMAT_RGB32 && prim->texture_palette == NULL)
                assert(TRUE);
            if (fmt == TEXFORMAT_ARGB32 && prim->texture_palette == NULL)
                assert(TRUE);
            if (fmt == TEXFORMAT_YUY16 && prim->texture_palette == NULL)
                assert(FALSE);

            if (fmt == TEXFORMAT_PALETTE16 && prim->texture_palette != NULL)
                assert(TRUE);
            if (fmt == TEXFORMAT_PALETTEA16 && prim->texture_palette != NULL)
                assert(FALSE);
            if (fmt == TEXFORMAT_RGB15 && prim->texture_palette != NULL)
                assert(TRUE);
            if (fmt == TEXFORMAT_RGB32 && prim->texture_palette != NULL)
                assert(TRUE);
            if (fmt == TEXFORMAT_ARGB32 && prim->texture_palette != NULL)
                assert(TRUE);
            if (fmt == TEXFORMAT_YUY16 && prim->texture_palette != NULL)
                assert(FALSE);
        }
    }
}
#endif

@end

