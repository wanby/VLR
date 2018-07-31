#include "kernel_common.cuh"
#include "random_distributions.cuh"

namespace VLR {
    RT_FUNCTION DirectionType sideTest(const Normal3D &ng, const Vector3D &d0, const Vector3D &d1) {
        bool reflect = dot(Vector3D(ng), d0) * dot(Vector3D(ng), d1) > 0;
        return DirectionType::AllFreq() | (reflect ? DirectionType::Reflection() : DirectionType::Transmission());
    }



    // ----------------------------------------------------------------
    // NullBSDF

    RT_CALLABLE_PROGRAM uint32_t NullBSDF_setupBSDF(const uint32_t* matDesc, const SurfacePoint &surfPt, bool wavelengthSelected, uint32_t* params) {
        return 0;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum NullBSDF_getBaseColor(const uint32_t* params) {
        return RGBSpectrum::Zero();
    }

    RT_CALLABLE_PROGRAM bool NullBSDF_matches(const uint32_t* params, DirectionType flags) {
        return false;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum NullBSDF_sampleBSDFInternal(const uint32_t* params, const BSDFQuery &query, float uComponent, const float uDir[2], BSDFQueryResult* result) {
        return RGBSpectrum::Zero();
    }

    RT_CALLABLE_PROGRAM RGBSpectrum NullBSDF_evaluateBSDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        return RGBSpectrum::Zero();
    }

    RT_CALLABLE_PROGRAM float NullBSDF_evaluateBSDF_PDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        return 0.0f;
    }

    RT_CALLABLE_PROGRAM float NullBSDF_weightInternal(const uint32_t* params, const BSDFQuery &query) {
        return 0.0f;
    }

    // END: NullBSDF
    // ----------------------------------------------------------------



    // ----------------------------------------------------------------
    // MatteBRDF

    struct MatteBRDF {
        RGBSpectrum albedo;
        float roughness;
    };

    RT_CALLABLE_PROGRAM uint32_t MatteSurfaceMaterial_setupBSDF(const uint32_t* matDesc, const SurfacePoint &surfPt, bool wavelengthSelected, uint32_t* params) {
        MatteBRDF &p = *(MatteBRDF*)params;
        const MatteSurfaceMaterial &mat = *(const MatteSurfaceMaterial*)(matDesc + sizeof(SurfaceMaterialHead) / 4);

        optix::float4 texValue = optix::rtTex2D<optix::float4>(mat.texAlbedoRoughness, surfPt.texCoord.u, surfPt.texCoord.v);
        p.albedo = sRGB_degamma(RGBSpectrum(texValue.x, texValue.y, texValue.z));
        p.roughness = texValue.w;

        return sizeof(MatteBRDF) / 4;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum MatteBRDF_getBaseColor(const uint32_t* params) {
        MatteBRDF &p = *(MatteBRDF*)params;

        return p.albedo;
    }

    RT_CALLABLE_PROGRAM bool MatteBRDF_matches(const uint32_t* params, DirectionType flags) {
        DirectionType m_type = DirectionType::Reflection() | DirectionType::LowFreq();
        return m_type.matches(flags);
    }

    RT_CALLABLE_PROGRAM RGBSpectrum MatteBRDF_sampleBSDFInternal(const uint32_t* params, const BSDFQuery &query, float uComponent, const float uDir[2], BSDFQueryResult* result) {
        MatteBRDF &p = *(MatteBRDF*)params;

        result->dirLocal = cosineSampleHemisphere(uDir[0], uDir[1]);
        result->dirPDF = result->dirLocal.z / M_PIf;
        result->sampledType = DirectionType::Reflection() | DirectionType::LowFreq();
        result->dirLocal.z *= query.dirLocal.z > 0 ? 1 : -1;

        return p.albedo / M_PIf;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum MatteBRDF_evaluateBSDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        MatteBRDF &p = *(MatteBRDF*)params;

        if (query.dirLocal.z * dirLocal.z <= 0.0f) {
            RGBSpectrum fs = RGBSpectrum::Zero();
            return fs;
        }
        RGBSpectrum fs = p.albedo / M_PIf;

        return fs;
    }

    RT_CALLABLE_PROGRAM float MatteBRDF_evaluateBSDF_PDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        if (query.dirLocal.z * dirLocal.z <= 0.0f) {
            return 0.0f;
        }

        return std::abs(dirLocal.z) / M_PIf;
    }

    RT_CALLABLE_PROGRAM float MatteBRDF_weightInternal(const uint32_t* params, const BSDFQuery &query) {
        MatteBRDF &p = *(MatteBRDF*)params;
        return p.albedo.importance(query.wlHint);
    }

    // END: MatteBRDF
    // ----------------------------------------------------------------



    RT_FUNCTION RGBSpectrum evaluateFresnelConductor(const RGBSpectrum &eta, const RGBSpectrum &k, float cosEnter) {
        cosEnter = std::fabs(cosEnter);
        float cosEnter2 = cosEnter * cosEnter;
        RGBSpectrum _2EtaCosEnter = 2.0f * eta * cosEnter;
        RGBSpectrum tmp_f = eta * eta + k * k;
        RGBSpectrum tmp = tmp_f * cosEnter2;
        RGBSpectrum Rparl2 = (tmp - _2EtaCosEnter + 1) / (tmp + _2EtaCosEnter + 1);
        RGBSpectrum Rperp2 = (tmp_f - _2EtaCosEnter + cosEnter2) / (tmp_f + _2EtaCosEnter + cosEnter2);
        return (Rparl2 + Rperp2) / 2.0f;
    }

    RT_FUNCTION float evalF(float etaEnter, float etaExit, float cosEnter, float cosExit) {
        float Rparl = ((etaExit * cosEnter) - (etaEnter * cosExit)) / ((etaExit * cosEnter) + (etaEnter * cosExit));
        float Rperp = ((etaEnter * cosEnter) - (etaExit * cosExit)) / ((etaEnter * cosEnter) + (etaExit * cosExit));
        return (Rparl * Rparl + Rperp * Rperp) / 2.0f;
    }

    RT_FUNCTION RGBSpectrum evaluateFresnelDielectric(const RGBSpectrum &etaExt, const RGBSpectrum &etaInt, float cosEnter) {
        cosEnter = std::fmin(std::fmax(cosEnter, -1.0f), 1.0f);

        bool entering = cosEnter > 0.0f;
        const RGBSpectrum &eEnter = entering ? etaExt : etaInt;
        const RGBSpectrum &eExit = entering ? etaInt : etaExt;

        RGBSpectrum sinExit = eEnter / eExit * std::sqrt(std::fmax(0.0f, 1.0f - cosEnter * cosEnter));
        RGBSpectrum ret = RGBSpectrum::Zero();
        cosEnter = std::fabs(cosEnter);
        for (int i = 0; i < RGBSpectrum::NumComponents(); ++i) {
            if (sinExit[i] >= 1.0f) {
                ret[i] = 1.0f;
            }
            else {
                float cosExit = std::sqrt(std::fmax(0.0f, 1.0f - sinExit[i] * sinExit[i]));
                ret[i] = evalF(eEnter[i], eExit[i], cosEnter, cosExit);
            }
        }

        return ret;
    }



    // ----------------------------------------------------------------
    // SpecularBRDF

    struct SpecularBRDF {
        RGBSpectrum coeffR;
        RGBSpectrum eta;
        RGBSpectrum k;
    };

    RT_CALLABLE_PROGRAM uint32_t SpecularReflectionSurfaceMaterial_setupBSDF(const uint32_t* matDesc, const SurfacePoint &surfPt, bool wavelengthSelected, uint32_t* params) {
        SpecularBRDF &p = *(SpecularBRDF*)params;
        const SpecularReflectionSurfaceMaterial &mat = *(const SpecularReflectionSurfaceMaterial*)(matDesc + sizeof(SurfaceMaterialHead) / 4);

        optix::float4 texValue;
        texValue = optix::rtTex2D<optix::float4>(mat.texCoeffR, surfPt.texCoord.u, surfPt.texCoord.v);
        p.coeffR = sRGB_degamma(RGBSpectrum(texValue.x, texValue.y, texValue.z));
        texValue = optix::rtTex2D<optix::float4>(mat.texEta, surfPt.texCoord.u, surfPt.texCoord.v);
        p.eta = RGBSpectrum(texValue.x, texValue.y, texValue.z);
        texValue = optix::rtTex2D<optix::float4>(mat.tex_k, surfPt.texCoord.u, surfPt.texCoord.v);
        p.k = RGBSpectrum(texValue.x, texValue.y, texValue.z);

        return sizeof(SpecularBRDF) / 4;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum SpecularBRDF_getBaseColor(const uint32_t* params) {
        SpecularBRDF &p = *(SpecularBRDF*)params;

        return p.coeffR;
    }

    RT_CALLABLE_PROGRAM bool SpecularBRDF_matches(const uint32_t* params, DirectionType flags) {
        DirectionType m_type = DirectionType::Reflection() | DirectionType::Delta0D();
        return m_type.matches(flags);
    }

    RT_CALLABLE_PROGRAM RGBSpectrum SpecularBRDF_sampleBSDFInternal(const uint32_t* params, const BSDFQuery &query, float uComponent, const float uDir[2], BSDFQueryResult* result) {
        SpecularBRDF &p = *(SpecularBRDF*)params;

        result->dirLocal = Vector3D(-query.dirLocal.x, -query.dirLocal.y, query.dirLocal.z);
        result->dirPDF = 1.0f;
        result->sampledType = DirectionType::Reflection() | DirectionType::Delta0D();
        RGBSpectrum fs = p.coeffR * evaluateFresnelConductor(p.eta, p.k, query.dirLocal.z) / std::fabs(query.dirLocal.z);

        return fs;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum SpecularBRDF_evaluateBSDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        return RGBSpectrum::Zero();
    }

    RT_CALLABLE_PROGRAM float SpecularBRDF_evaluateBSDF_PDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        return 0.0f;
    }

    RT_CALLABLE_PROGRAM float SpecularBRDF_weightInternal(const uint32_t* params, const BSDFQuery &query) {
        SpecularBRDF &p = *(SpecularBRDF*)params;
        float ret = (p.coeffR * evaluateFresnelConductor(p.eta, p.k, query.dirLocal.z)).importance(query.wlHint);
        //float snCorrection = query.adjoint ? std::fabs(dot(Vector3D(-query.dirLocal.x, -query.dirLocal.y, query.dirLocal.z), query.gNormalLocal) /
        //                                               query.dirLocal.z) : 1;
        return ret;
    }

    // END: SpecularBRDF
    // ----------------------------------------------------------------



    // ----------------------------------------------------------------
    // SpecularBSDF

    struct SpecularBSDF {
        RGBSpectrum coeff;
        RGBSpectrum etaExt;
        RGBSpectrum etaInt;
        bool dispersive;
    };

    RT_CALLABLE_PROGRAM uint32_t SpecularScatteringSurfaceMaterial_setupBSDF(const uint32_t* matDesc, const SurfacePoint &surfPt, bool wavelengthSelected, uint32_t* params) {
        SpecularBSDF &p = *(SpecularBSDF*)params;
        const SpecularScatteringSurfaceMaterial &mat = *(const SpecularScatteringSurfaceMaterial*)(matDesc + sizeof(SurfaceMaterialHead) / 4);

        optix::float4 texValue;
        texValue = optix::rtTex2D<optix::float4>(mat.texCoeff, surfPt.texCoord.u, surfPt.texCoord.v);
        p.coeff = sRGB_degamma(RGBSpectrum(texValue.x, texValue.y, texValue.z));
        texValue = optix::rtTex2D<optix::float4>(mat.texEtaExt, surfPt.texCoord.u, surfPt.texCoord.v);
        p.etaExt = RGBSpectrum(texValue.x, texValue.y, texValue.z);
        texValue = optix::rtTex2D<optix::float4>(mat.texEtaInt, surfPt.texCoord.u, surfPt.texCoord.v);
        p.etaInt = RGBSpectrum(texValue.x, texValue.y, texValue.z);
        p.dispersive = !wavelengthSelected;

        return sizeof(SpecularBSDF) / 4;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum SpecularBSDF_getBaseColor(const uint32_t* params) {
        SpecularBSDF &p = *(SpecularBSDF*)params;

        return p.coeff;
    }

    RT_CALLABLE_PROGRAM bool SpecularBSDF_matches(const uint32_t* params, DirectionType flags) {
        DirectionType m_type = DirectionType::WholeSphere() | DirectionType::Delta0D();
        return m_type.matches(flags);
    }

    RT_CALLABLE_PROGRAM RGBSpectrum SpecularBSDF_sampleBSDFInternal(const uint32_t* params, const BSDFQuery &query, float uComponent, const float uDir[2], BSDFQueryResult* result) {
        SpecularBSDF &p = *(SpecularBSDF*)params;

        RGBSpectrum F = evaluateFresnelDielectric(p.etaExt, p.etaInt, query.dirLocal.z);
        float reflectProb = F.importance(query.wlHint);
        if (query.dirTypeFilter.isReflection())
            reflectProb = 1.0f;
        if (query.dirTypeFilter.isTransmission())
            reflectProb = 0.0f;
        if (uComponent < reflectProb) {
            if (query.dirLocal.z == 0.0f) {
                result->dirPDF = 0.0f;
                return RGBSpectrum::Zero();
            }
            result->dirLocal = Vector3D(-query.dirLocal.x, -query.dirLocal.y, query.dirLocal.z);
            result->dirPDF = reflectProb;
            result->sampledType = DirectionType::Reflection() | DirectionType::Delta0D();
            RGBSpectrum fs = p.coeff * F / std::fabs(query.dirLocal.z);

            return fs;
        }
        else {
            bool entering = query.dirLocal.z > 0.0f;
            float eEnter = entering ? p.etaExt[query.wlHint] : p.etaInt[query.wlHint];
            float eExit = entering ? p.etaInt[query.wlHint] : p.etaExt[query.wlHint];

            float sinEnter2 = 1.0f - query.dirLocal.z * query.dirLocal.z;
            float rrEta = eEnter / eExit;// reciprocal of relative IOR.
            float sinExit2 = rrEta * rrEta * sinEnter2;

            if (sinExit2 >= 1.0f) {
                result->dirPDF = 0.0f;
                return RGBSpectrum::Zero();
            }
            float cosExit = std::sqrt(std::fmax(0.0f, 1.0f - sinExit2));
            if (entering)
                cosExit = -cosExit;
            result->dirLocal = Vector3D(rrEta * -query.dirLocal.x, rrEta * -query.dirLocal.y, cosExit);
            result->dirPDF = 1.0f - reflectProb;
            result->sampledType = DirectionType::Transmission() | DirectionType::Delta0D() | (p.dispersive ? DirectionType::Dispersive() : DirectionType());
            RGBSpectrum ret = RGBSpectrum::Zero();
            ret[query.wlHint] = p.coeff[query.wlHint] * (1.0f - F[query.wlHint]);
            RGBSpectrum fs = ret / std::fabs(cosExit);

            return fs;
        }
    }

    RT_CALLABLE_PROGRAM RGBSpectrum SpecularBSDF_evaluateBSDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        return RGBSpectrum::Zero();
    }

    RT_CALLABLE_PROGRAM float SpecularBSDF_evaluateBSDF_PDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        return 0.0f;
    }

    RT_CALLABLE_PROGRAM float SpecularBSDF_weightInternal(const uint32_t* params, const BSDFQuery &query) {
        SpecularBSDF &p = *(SpecularBSDF*)params;
        return p.coeff.importance(query.wlHint);
    }

    // END: SpecularBSDF
    // ----------------------------------------------------------------



    // ----------------------------------------------------------------
    // UE4 BRDF

    struct UE4BRDF {
        RGBSpectrum baseColor;
        float roughenss;
        float metallic;
    };

    RT_CALLABLE_PROGRAM uint32_t UE4SurfaceMaterial_setupBSDF(const uint32_t* matDesc, const SurfacePoint &surfPt, bool wavelengthSelected, uint32_t* params) {
        UE4BRDF &p = *(UE4BRDF*)params;
        const UE4SurfaceMaterial &mat = *(const UE4SurfaceMaterial*)(matDesc + sizeof(SurfaceMaterialHead) / 4);

        VLRAssert_NotImplemented();

        return sizeof(UE4BRDF) / 4;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum UE4BRDF_getBaseColor(const uint32_t* params) {
        VLRAssert_NotImplemented();
        return RGBSpectrum::Zero();
    }
    
    RT_CALLABLE_PROGRAM bool UE4BRDF_matches(const uint32_t* params, DirectionType flags) {
        VLRAssert_NotImplemented();
        return true;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum UE4BRDF_sampleBSDFInternal(const uint32_t* params, const BSDFQuery &query, float uComponent, const float uDir[2], BSDFQueryResult* result) {
        VLRAssert_NotImplemented();
        return RGBSpectrum::Zero();
    }

    RT_CALLABLE_PROGRAM RGBSpectrum UE4BRDF_evaluateBSDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        VLRAssert_NotImplemented();
        return RGBSpectrum::Zero();
    }

    RT_CALLABLE_PROGRAM float UE4BRDF_evaluateBSDF_PDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        VLRAssert_NotImplemented();
        return 0.0f;
    }

    RT_CALLABLE_PROGRAM float UE4BRDF_weightInternal(const uint32_t* params, const BSDFQuery &query) {
        VLRAssert_NotImplemented();
        return 0.0f;
    }

    // END: UE4 BRDF
    // ----------------------------------------------------------------



    // ----------------------------------------------------------------
    // NullEDF

    RT_CALLABLE_PROGRAM uint32_t NullEDF_setupEDF(const uint32_t* matDesc, const SurfacePoint &surfPt, uint32_t* params) {
        return 0;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum NullEDF_evaluateEmittanceInternal(const uint32_t* params) {
        return RGBSpectrum::Zero();
    }

    RT_CALLABLE_PROGRAM RGBSpectrum NullEDF_evaluateEDFInternal(const uint32_t* params, const EDFQuery &query, const Vector3D &dirLocal) {
        return RGBSpectrum::Zero();
    }

    // END: NullEDF
    // ----------------------------------------------------------------


    
    // ----------------------------------------------------------------
    // DiffuseEDF

    struct DiffuseEDF {
        RGBSpectrum emittance;
    };

    RT_CALLABLE_PROGRAM uint32_t DiffuseEmitterSurfaceMaterial_setupEDF(const uint32_t* matDesc, const SurfacePoint &surfPt, uint32_t* params) {
        DiffuseEDF &p = *(DiffuseEDF*)params;
        const DiffuseEmitterSurfaceMaterial &mat = *(const DiffuseEmitterSurfaceMaterial*)(matDesc + sizeof(SurfaceMaterialHead) / 4);

        optix::float4 texValue = optix::rtTex2D<optix::float4>(mat.texEmittance, surfPt.texCoord.u, surfPt.texCoord.v);
        p.emittance = RGBSpectrum(texValue.x, texValue.y, texValue.z);

        return sizeof(DiffuseEDF) / 4;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum DiffuseEDF_evaluateEmittanceInternal(const uint32_t* params) {
        DiffuseEDF &p = *(DiffuseEDF*)params;
        return p.emittance;
    }
    
    RT_CALLABLE_PROGRAM RGBSpectrum DiffuseEDF_evaluateEDFInternal(const uint32_t* params, const EDFQuery &query, const Vector3D &dirLocal) {
        return RGBSpectrum(dirLocal.z > 0.0f ? 1.0f / M_PIf : 0.0f);
    }

    // END: DiffuseEDF
    // ----------------------------------------------------------------



    // ----------------------------------------------------------------
    // MultiBSDF / MultiEDF

    // bsdf0-3: param offsets
    // numBSDFs
    // --------------------------------
    // BSDF0 procedure set index
    // BSDF0 params
    // ...
    // BSDF3 procedure set index
    // BSDF3 params
    struct MultiBSDF {
        struct {
            unsigned int bsdf0 : 6;
            unsigned int bsdf1 : 6;
            unsigned int bsdf2 : 6;
            unsigned int bsdf3 : 6;
            unsigned int numBSDFs : 8;
        };
    };

    RT_CALLABLE_PROGRAM uint32_t MultiSurfaceMaterial_setupBSDF(const uint32_t* matDesc, const SurfacePoint &surfPt, bool wavelengthSelected, uint32_t* params) {
        MultiBSDF &p = *(MultiBSDF*)params;
        const MultiSurfaceMaterial &mat = *(const MultiSurfaceMaterial*)(matDesc + sizeof(SurfaceMaterialHead) / 4);

        uint32_t baseIndex = sizeof(MultiBSDF) / 4;
        const uint32_t matOffsets[] = { mat.matOffset0, mat.matOffset1, mat.matOffset2, mat.matOffset3 };
        uint32_t bsdfOffsets[4] = { 0, 0, 0, 0 };
        for (int i = 0; i < mat.numMaterials; ++i) {
            bsdfOffsets[i] = baseIndex;

            const SurfaceMaterialHead &matHead = *(const SurfaceMaterialHead*)(matDesc + matOffsets[i]);
            //rtPrintf("%d: %u, %u, %u, %u\n", i, matHead.progSetupBSDF, matHead.bsdfProcedureSetIndex, matHead.progSetupEDF, matHead.edfProcedureSetIndex);
            progSigSetupBSDF setupBSDF = (progSigSetupBSDF)matHead.progSetupBSDF;
            *(uint32_t*)(params + baseIndex++) = matHead.bsdfProcedureSetIndex;
            baseIndex += setupBSDF((const uint32_t*)&matHead, surfPt, wavelengthSelected, params + baseIndex);
        }

        p.bsdf0 = bsdfOffsets[0];
        p.bsdf1 = bsdfOffsets[1];
        p.bsdf2 = bsdfOffsets[2];
        p.bsdf3 = bsdfOffsets[3];
        p.numBSDFs = mat.numMaterials;

        //rtPrintf("%u, %u, %u, %u, %u mats\n", p.bsdf0, p.bsdf1, p.bsdf2, p.bsdf3, p.numBSDFs);

        return baseIndex;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum MultiBSDF_getBaseColor(const uint32_t* params) {
        const MultiBSDF &p = *(const MultiBSDF*)params;

        uint32_t bsdfOffsets[4] = { p.bsdf0, p.bsdf1, p.bsdf2, p.bsdf3 };

        RGBSpectrum ret;
        for (int i = 0; i < p.numBSDFs; ++i) {
            const uint32_t* bsdf = params + bsdfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)bsdf;
            const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
            progSigGetBaseColor getBaseColor = (progSigGetBaseColor)procSet.progGetBaseColor;

            ret += getBaseColor(bsdf + 1);
        }

        return ret;
    }

    RT_CALLABLE_PROGRAM bool MultiBSDF_matches(const uint32_t* params, DirectionType flags) {
        const MultiBSDF &p = *(const MultiBSDF*)params;

        uint32_t bsdfOffsets[4] = { p.bsdf0, p.bsdf1, p.bsdf2, p.bsdf3 };

        for (int i = 0; i < p.numBSDFs; ++i) {
            const uint32_t* bsdf = params + bsdfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)bsdf;
            const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
            progSigBSDFmatches matches = (progSigBSDFmatches)procSet.progBSDFmatches;

            if (matches(bsdf + 1, flags))
                return true;
        }

        return false;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum MultiBSDF_sampleBSDFInternal(const uint32_t* params, const BSDFQuery &query, float uComponent, const float uDir[2], BSDFQueryResult* result) {
        const MultiBSDF &p = *(const MultiBSDF*)params;

        uint32_t bsdfOffsets[4] = { p.bsdf0, p.bsdf1, p.bsdf2, p.bsdf3 };

        float weights[4];
        for (int i = 0; i < p.numBSDFs; ++i) {
            const uint32_t* bsdf = params + bsdfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)bsdf;
            const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
            progSigBSDFWeightInternal weightInternal = (progSigBSDFWeightInternal)procSet.progWeightInternal;

            weights[i] = weightInternal(bsdf + 1, query);
        }

        // JP: �eBSDF�̃E�F�C�g�Ɋ�Â��ĕ����̃T���v�����s��BSDF��I������B
        // EN: Based on the weight of each BSDF, select a BSDF from which direction sampling.
        float tempProb;
        float sumWeights;
        uint32_t idx = sampleDiscrete(weights, p.numBSDFs, uComponent, &tempProb, &sumWeights, &uComponent);
        if (sumWeights == 0.0f) {
            result->dirPDF = 0.0f;
            return RGBSpectrum::Zero();
        }

        const uint32_t* selectedBSDF = params + bsdfOffsets[idx];
        uint32_t selProcIdx = *(const uint32_t*)selectedBSDF;
        const BSDFProcedureSet selProcSet = pv_bsdfProcedureSetBuffer[selProcIdx];
        progSigSampleBSDFInternal sampleInternal = (progSigSampleBSDFInternal)selProcSet.progSampleBSDFInternal;

        // JP: �I������BSDF����������T���v�����O����B
        // EN: sample a direction from the selected BSDF.
        RGBSpectrum value = sampleInternal(selectedBSDF + 1, query, uComponent, uDir, result);
        result->dirPDF *= weights[idx];
        if (result->dirPDF == 0.0f) {
            result->dirPDF = 0.0f;
            return RGBSpectrum::Zero();
        }

        // JP: �T���v�����������Ɋւ���BSDF�̒l�̍��v�ƁAsingle-sample model MIS�Ɋ�Â����m�����x���v�Z����B
        // EN: calculate the total of BSDF values and a PDF based on the single-sample model MIS for the sampled direction.
        if (!result->sampledType.isDelta()) {
            for (int i = 0; i < p.numBSDFs; ++i) {
                const uint32_t* bsdf = params + bsdfOffsets[i];
                uint32_t procIdx = *(const uint32_t*)bsdf;
                const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
                progSigBSDFmatches matches = (progSigBSDFmatches)procSet.progBSDFmatches;
                progSigEvaluateBSDF_PDFInternal evaluatePDFInternal = (progSigEvaluateBSDF_PDFInternal)procSet.progEvaluateBSDF_PDFInternal;

                if (i != idx && matches(bsdf + 1, query.dirTypeFilter))
                    result->dirPDF += evaluatePDFInternal(bsdf + 1, query, result->dirLocal) * weights[i];
            }

            BSDFQuery mQuery = query;
            mQuery.dirTypeFilter &= sideTest(query.geometricNormalLocal, query.dirLocal, result->dirLocal);
            value = RGBSpectrum::Zero();
            for (int i = 0; i < p.numBSDFs; ++i) {
                const uint32_t* bsdf = params + bsdfOffsets[i];
                uint32_t procIdx = *(const uint32_t*)bsdf;
                const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
                progSigBSDFmatches matches = (progSigBSDFmatches)procSet.progBSDFmatches;
                progSigEvaluateBSDFInternal evaluateBSDFInternal = (progSigEvaluateBSDFInternal)procSet.progEvaluateBSDFInternal;

                if (!matches(bsdf + 1, mQuery.dirTypeFilter))
                    continue;
                value += evaluateBSDFInternal(bsdf + 1, mQuery, result->dirLocal);
            }
        }
        result->dirPDF /= sumWeights;

        return value;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum MultiBSDF_evaluateBSDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        const MultiBSDF &p = *(const MultiBSDF*)params;

        uint32_t bsdfOffsets[4] = { p.bsdf0, p.bsdf1, p.bsdf2, p.bsdf3 };

        RGBSpectrum retValue = RGBSpectrum::Zero();
        for (int i = 0; i < p.numBSDFs; ++i) {
            const uint32_t* bsdf = params + bsdfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)bsdf;
            const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
            progSigBSDFmatches matches = (progSigBSDFmatches)procSet.progBSDFmatches;
            progSigEvaluateBSDFInternal evaluateBSDFInternal = (progSigEvaluateBSDFInternal)procSet.progEvaluateBSDFInternal;

            if (!matches(bsdf + 1, query.dirTypeFilter))
                continue;
            retValue += evaluateBSDFInternal(bsdf + 1, query, dirLocal);
        }
        return retValue;
    }

    RT_CALLABLE_PROGRAM float MultiBSDF_evaluateBSDF_PDFInternal(const uint32_t* params, const BSDFQuery &query, const Vector3D &dirLocal) {
        const MultiBSDF &p = *(const MultiBSDF*)params;

        uint32_t bsdfOffsets[4] = { p.bsdf0, p.bsdf1, p.bsdf2, p.bsdf3 };

        float sumWeights = 0.0f;
        float weights[4];
        for (int i = 0; i < p.numBSDFs; ++i) {
            const uint32_t* bsdf = params + bsdfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)bsdf;
            const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
            progSigBSDFWeightInternal weightInternal = (progSigBSDFWeightInternal)procSet.progWeightInternal;

            weights[i] = weightInternal(bsdf + 1, query);
            sumWeights += weights[i];
        }
        if (sumWeights == 0.0f)
            return 0.0f;

        float retPDF = 0.0f;
        for (int i = 0; i < p.numBSDFs; ++i) {
            const uint32_t* bsdf = params + bsdfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)bsdf;
            const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
            progSigEvaluateBSDF_PDFInternal evaluatePDFInternal = (progSigEvaluateBSDF_PDFInternal)procSet.progEvaluateBSDF_PDFInternal;

            if (weights[i] > 0)
                retPDF += evaluatePDFInternal(bsdf + 1, query, dirLocal) * weights[i];
        }
        retPDF /= sumWeights;

        return retPDF;
    }

    RT_CALLABLE_PROGRAM float MultiBSDF_weightInternal(const uint32_t* params, const BSDFQuery &query) {
        const MultiBSDF &p = *(const MultiBSDF*)params;

        uint32_t bsdfOffsets[4] = { p.bsdf0, p.bsdf1, p.bsdf2, p.bsdf3 };

        float ret = 0.0f;
        for (int i = 0; i < p.numBSDFs; ++i) {
            const uint32_t* bsdf = params + bsdfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)bsdf;
            const BSDFProcedureSet procSet = pv_bsdfProcedureSetBuffer[procIdx];
            progSigBSDFWeightInternal weightInternal = (progSigBSDFWeightInternal)procSet.progWeightInternal;

            ret += weightInternal(bsdf + 1, query);
        }

        return ret;
    }

    // edf0-3: param offsets
    // numEDFs
    // --------------------------------
    // EDF0 procedure set index
    // EDF0 params
    // ...
    // EDF3 procedure set index
    // EDF3 params
    struct MultiEDF {
        struct {
            unsigned int edf0 : 6;
            unsigned int edf1 : 6;
            unsigned int edf2 : 6;
            unsigned int edf3 : 6;
            unsigned int numEDFs : 8;
        };
    };

    RT_CALLABLE_PROGRAM uint32_t MultiSurfaceMaterial_setupEDF(const uint32_t* matDesc, const SurfacePoint &surfPt, uint32_t* params) {
        MultiEDF &p = *(MultiEDF*)params;
        const MultiSurfaceMaterial &mat = *(const MultiSurfaceMaterial*)(matDesc + sizeof(SurfaceMaterialHead) / 4);

        uint32_t baseIndex = sizeof(MultiEDF) / 4;
        const uint32_t matOffsets[] = { mat.matOffset0, mat.matOffset1, mat.matOffset2, mat.matOffset3 };
        uint32_t edfOffsets[4] = { 0, 0, 0, 0 };
        for (int i = 0; i < mat.numMaterials; ++i) {
            edfOffsets[i] = baseIndex;

            const SurfaceMaterialHead &matHead = *(const SurfaceMaterialHead*)(matDesc + matOffsets[i]);
            progSigSetupEDF setupEDF = (progSigSetupEDF)matHead.progSetupEDF;
            *(uint32_t*)(params + baseIndex++) = matHead.edfProcedureSetIndex;
            baseIndex += setupEDF((const uint32_t*)&matHead, surfPt, params + baseIndex);
        }

        p.edf0 = edfOffsets[0];
        p.edf1 = edfOffsets[1];
        p.edf2 = edfOffsets[2];
        p.edf3 = edfOffsets[3];
        p.numEDFs = mat.numMaterials;

        return baseIndex;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum MultiEDF_evaluateEmittanceInternal(const uint32_t* params) {
        const MultiEDF &p = *(const MultiEDF*)params;

        uint32_t edfOffsets[4] = { p.edf0, p.edf1, p.edf2, p.edf3 };

        RGBSpectrum ret = RGBSpectrum::Zero();
        for (int i = 0; i < p.numEDFs; ++i) {
            const uint32_t* edf = params + edfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)edf;
            const EDFProcedureSet procSet = pv_edfProcedureSetBuffer[procIdx];
            progSigEvaluateEmittanceInternal evaluateEmittanceInternal = (progSigEvaluateEmittanceInternal)procSet.progEvaluateEmittanceInternal;

            ret += evaluateEmittanceInternal(edf + 1);
        }

        return ret;
    }

    RT_CALLABLE_PROGRAM RGBSpectrum MultiEDF_evaluateEDFInternal(const uint32_t* params, const EDFQuery &query, const Vector3D &dirLocal) {
        const MultiEDF &p = *(const MultiEDF*)params;

        uint32_t edfOffsets[4] = { p.edf0, p.edf1, p.edf2, p.edf3 };

        RGBSpectrum ret = RGBSpectrum::Zero();
        RGBSpectrum sumEmittance = RGBSpectrum::Zero();
        for (int i = 0; i < p.numEDFs; ++i) {
            const uint32_t* edf = params + edfOffsets[i];
            uint32_t procIdx = *(const uint32_t*)edf;
            const EDFProcedureSet procSet = pv_edfProcedureSetBuffer[procIdx];
            progSigEvaluateEmittanceInternal evaluateEmittanceInternal = (progSigEvaluateEmittanceInternal)procSet.progEvaluateEmittanceInternal;
            progSigEvaluateEDFInternal evaluateEDFInternal = (progSigEvaluateEDFInternal)procSet.progEvaluateEDFInternal;

            RGBSpectrum emittance = evaluateEmittanceInternal(edf + 1);
            sumEmittance += emittance;
            ret += emittance * evaluateEDFInternal(edf + 1, query, dirLocal);
        }
        ret.safeDivide(sumEmittance);

        return ret;
    }

    // END: MultiBSDF / MultiEDF
    // ----------------------------------------------------------------
}