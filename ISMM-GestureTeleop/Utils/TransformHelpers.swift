//
//  TransformHelpers.swift
//  ISMM-GestureTeleop
//
//  Created by Andrew Pasco on 10/06/25.
//

import simd

// simd matrices are init as (col1, col2, col3, ..., coln)

public func rotx(_ angle: simd_double1) -> simd_double3x3 {
    return simd_double3x3(
        [1,  0,            0         ],
        [0,  cos(angle),   sin(angle)],
        [0, -sin(angle),   cos(angle)]
    )
}

public func roty(_ angle: simd_double1) -> simd_double3x3 {
    return simd_double3x3(
        [cos(angle), 0,  -sin(angle)],
        [0,          1,   0         ],
        [sin(angle), 0,   cos(angle)]
    )
}

public func rotz(_ angle: simd_double1) -> simd_double3x3 {
    return simd_double3x3(
        [ cos(angle), sin(angle), 0],
        [-sin(angle), cos(angle), 0],
        [ 0,          0,          1]
    )
}

public func transformFromRot(_ rot: simd_double3x3) -> simd_double4x4 {
    return simd_double4x4(
        simd_make_double4(rot[0],  0),
        simd_make_double4(rot[1],  0),
        simd_make_double4(rot[2],  0),
        simd_make_double4(0, 0, 0, 1)
    )
}

public func poseMatrix(pos: simd_double3, rot:simd_double3x3) -> simd_double4x4 {
    return simd_double4x4(
        simd_double4(rot[0], 0),
        simd_double4(rot[1], 0),
        simd_double4(rot[2], 0),
        simd_double4(pos.x, pos.y, pos.z, 1)
        )
}

public func posRotFromMat(_ mat: simd_double4x4) -> (pos: simd_double3, rot: simd_double3x3) {
    let pos = simd_double3(mat.columns.3.x, mat.columns.3.y, mat.columns.3.z)
    let rot = simd_double3x3(
        simd_double3(mat.columns.0.x, mat.columns.0.y, mat.columns.0.z),
        simd_double3(mat.columns.1.x, mat.columns.1.y, mat.columns.1.z),
        simd_double3(mat.columns.2.x, mat.columns.2.y, mat.columns.2.z)
    )
    return (pos, rot)
}

// Helper: skew-symmetric cross product matrix from a 3-vector
func crossmat(_ v: simd_double3) -> simd_double3x3 {
    return simd_double3x3(rows: [
        simd_double3( 0,     -v.z,   v.y),
        simd_double3( v.z,    0,    -v.x),
        simd_double3(-v.y,   v.x,    0)
    ])
}

func R_from_quat(_ quat: simd_quatd) -> simd_double3x3 {
    // Flatten quaternion to array [w, x, y, z]
    let q = [quat.real, quat.imag.x, quat.imag.y, quat.imag.z]
    
    // Compute norm squared
    let norm2 = q.reduce(0) { $0 + $1 * $1 }
    
    // Extract scalar w and vector v
    let w = q[0]
    let v = simd_double3(q[1], q[2], q[3])
    
    let I = matrix_identity_double3x3
    let vvT = simd_double3x3(rows: [
        simd_double3(v.x * v.x, v.x * v.y, v.x * v.z),
        simd_double3(v.y * v.x, v.y * v.y, v.y * v.z),
        simd_double3(v.z * v.x, v.z * v.y, v.z * v.z)
    ])
    
    let R = (2.0 / norm2) * (vvT + (w * w) * I + w * crossmat(v)) - I
    
    return R
}
