tochar(x) = eltype(x) == String ? first.(x) : x
function parse_ref(ref_file, chrom)
    println("Parsing reference file: $ref_file")
    df = CSV.File(ref_file) |> DataFrame
    df.A1 = tochar(df.A1)
    df.A2 = tochar(df.A2)
    @assert df.CHR isa Vector{Int}
    @assert df.BP isa Vector{Int}
    @assert df.MAF isa Vector{T} where T<:Real
    filter!(row->row.CHR == chrom, df)
    println("$(nrow(df)) SNPs on chromosome $chrom in reference file")
    return df
end
function parse_bim(bim_file, chrom)
    println("Parsing BIM file: $(bim_file*".bim")")
    header = [:CHR, :SNP, :POS, :BP, :A1, :A2]
    df = CSV.File(bim_file*".bim"; header=header) |> DataFrame
    df.A1 = tochar(df.A1)
    df.A2 = tochar(df.A2)
    @assert df.CHR isa Vector{Int}
    filter!(row->row.CHR == chrom, df)
    println("$(nrow(df)) SNPs in BIM file")
    return df
end
# TODO: Remove need for String method
#nuc_map(str::String) = String(nuc_map(first(str)))
nuc_map(char::Char) = nuc_map(Val(char))
nuc_map(::Val{'A'}) = 'T'
nuc_map(::Val{'T'}) = 'A'
nuc_map(::Val{'C'}) = 'G'
nuc_map(::Val{'G'}) = 'C'
function permute_snps(df)
    vcat(
        df[!,[:SNP,:A1,:A2]],
        DataFrame(SNP=df.SNP, A1=df.A2, A2=df.A1),
        DataFrame(SNP=df.SNP,
                  A1=nuc_map.(first.(df.A1)),
                  A2=nuc_map.(first.(df.A2))),
        DataFrame(SNP=df.SNP,
                  A1=nuc_map.(first.(df.A2)),
                  A2=nuc_map.(first.(df.A1)))
    )
end
function join_snps(ref_df, vld_df, sst_df)
    # TODO: Be more efficient, don't allocate all this memory
    vld_snps = vld_df[!,[:SNP,:A1,:A2]]
    ref_snps = permute_snps(ref_df)
    sst_snps = permute_snps(sst_df)
    snps = unique(vcat(vld_snps, ref_snps, sst_snps))
    println("$(nrow(snps)) common SNPs")
    return snps
end
function findfuzzysnp(df, snp)
    for (idx,row) in enumerate(Tables.namedtupleiterator(df))
        if Tuple(row) == snp
            return idx
        elseif (row.SNP,nuc_map(row.A1),nuc_map(row.A1)) == snp
            return idx
        end
    end
    return nothing
end
# FIXME: norm_ppf
norm_ppf(x) = x
function parse_sumstats(ref_df, vld_df, sst_file, chrom, n_subj)
    println("Parsing summary statistics file: $sst_file")
    sst_df = CSV.File(sst_file) |> DataFrame
    sst_df.A1 = tochar(sst_df.A1)
    sst_df.A2 = tochar(sst_df.A2)
    @assert sst_df.BETA isa Vector{T} where T<:Real
    snps = join_snps(ref_df, vld_df, sst_df)
    sort!(snps, (:SNP, :A1, :A2))

    n_sqrt = sqrt(n_subj)
    sst_eff = Dict{String,Float64}()
    for row in Tables.namedtupleiterator(sst_df)
        snp_rowidx = findsnp(snps, (row.SNP,row.A1,row.A2))
        if snp_rowidx !== nothing
            effect_sign = 1
        else
            snp_rowidx_flip = findsnp(snps, (row.SNP,row.A2,row.A1))
            snp_rowidx_flip === nothing && continue
            effect_sign = -1
        end
        if hasproperty(row, :BETA)
            beta = row.BETA
        elseif hasproperty(row, :OR)
            beta = log(row.OR)
        end
        p = max(row.P, 1e-323)
        beta_std = effect_sign*sign(beta)*abs(norm_ppf(p/2))/n_sqrt
        sst_eff[row.SNP] = beta_std
    end
    _sst_df = similar(sst_df, 0)
    deletecols!(_sst_df, :P)
    _sst_df.FLP = Int[]
    for (idx,row) in enumerate(Tables.namedtupleiterator(ref_df))
        haskey(sst_eff, row.SNP) || continue

        SNP = row.SNP
        CHR = row.CHR
        BP = row.BP
        BETA = sst_eff[row.SNP]
        A1,A2 = row.A1,row.A2
        if hassnp(snps, (SNP,A1,A2))
            MAF = row.MAF
            FLP = 1
        elseif hassnp(snps, (SNP,A2,A1))
            A1, A2 = A2, A1
            MAF = 1-row.MAF
            FLP = -1
        elseif hassnp(snps, (SNP,nuc_map(A1),nuc_map(A2)))
            A1 = nuc_map(A1)
            A2 = nuc_map(A2)
            MAF = row.MAF
            FLP = 1
        elseif hassnp(snps, (SNP,nuc_map(A2),nuc_map(A1)))
            A1 = nuc_map(A2)
            A2 = nuc_map(A1)
            MAF = 1-row.MAF
            FLP = -1
        end
        push!(_sst_df, (SNP=SNP,CHR=CHR,BP=BP,BETA=BETA,A1=A1,A2=A2,MAF=MAF,FLP=FLP))
    end
    println("$(nrow(_sst_df)) SNPs in summary statistics file")
    return _sst_df
end

function findsnp(snps, (snp,a1,a2))
    SNP_range = binary_range_search(snps, snp, :SNP)
    SNP_range === nothing && return nothing
    SNP_L, SNP_R = SNP_range
    SNP_sub = snps[SNP_L:SNP_R,:]

    A1_range = binary_range_search(SNP_sub, a1, :A1)
    A1_range === nothing && return nothing
    A1_L, A1_R = A1_range
    A1_sub = SNP_sub[A1_L:A1_R,:]

    A2_range = binary_range_search(A1_sub, a2, :A2)
    A2_range === nothing && return nothing
    A2_L, A2_R = A2_range
    @assert A2_L == A2_R
    return SNP_L + (A1_L-1) + (A2_L-1)
end
hassnp(snps, row) = findsnp(snps, row) !== nothing
function binary_range_search(snps, x, col)
    _snps = snps[!,col]
    L = 1
    R = nrow(snps)+1
    while true
        L < R || return nothing
        M = floor(Int, (L+R)/2)
        _x = _snps[M]
        if _x == x
            L,R = M,M
            snps_rows = nrow(snps)
            while L > 1 && _snps[L - 1] == x
                L -= 1
            end
            while R < snps_rows && _snps[R + 1] == x
                R += 1
            end
            return L,R
        elseif _x < x
            L = M+1
        elseif _x > x
            R = M-1
        end
    end
end

function parse_ldblk(ldblk_dir, sst_df, chrom)
    println("Parsing reference LD on chromosome $chrom")
    error("Not yet implemented")
end
