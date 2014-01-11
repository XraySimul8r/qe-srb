#define W_TOL 0.00001
#define BLOCK_SIZE 1024

subroutine transform_rho(rho_srb, opt_basis, rho)
  use kinds, only : DP
  use srb_types, only : basis
  use srb_matrix, only : dmat, copy_dmat, diag
  use scf, only : scf_type
  use cell_base, only : omega, tpiba2
  use uspp, only : nkb
  use uspp_param, only : nh, nhm
  use ions_base, only : nat, ityp, nsp

  use srb, only : decomp_size
  use buffers, only : get_buffer, save_buffer, open_buffer
  use gvecs, only : nls
  use gvect, only : ngm, g, nl
  use wavefunctions_module, only : psic
  use fft_base, only : dfftp, dffts
  use fft_interfaces, only : invfft, fwfft
  use symme, only : sym_rho 
  use scalapack_mod, only : scalapack_localindex
  use mp, only : mp_sum
  use mp_global, only : intra_pool_comm, me_image
  USE wvfct, only: ecutwfc_int => ecutwfc

  IMPLICIT NONE

  type(dmat), intent(in) :: rho_srb(:)
  type(basis), intent(inout) :: opt_basis
  type(scf_type), intent(inout) :: rho

  ! locals
  integer :: npw, nbasis, nspin
  integer :: i, ibnd, ir, max_band
  complex(DP), parameter :: zero = (0.d0, 0.d0), one = (1.d0, 0.d0)
  integer :: spin, offset, num
  complex(DP), allocatable :: tmp(:,:)

  real(DP), parameter :: k_gamma(3) = 0.d0
  integer, allocatable :: igk(:)
  real(DP), allocatable :: g2kin(:)

  real(DP), allocatable :: S(:)
  type(dmat) :: sv
  complex(DP), allocatable :: work(:)
  real(DP), allocatable :: rwork(:)
  integer, allocatable :: iwork(:)
  integer :: lwork, lrwork, liwork
  real(DP) :: trace, trace2
  integer, save :: funit = -128
  logical :: info

  npw   = size(opt_basis%elements, 1)
  nbasis = opt_basis%length
  nspin = size(rho_srb)

  allocate(igk(ngm), g2kin(ngm))
  call gk_sort(k_gamma, ngm, g, ecutwfc_int/tpiba2, npw, igk, g2kin)

  allocate(S(nbasis))
  call copy_dmat(sv, rho_srb(1))

  do spin = 1, nspin

  ! find the rank-1 decomposition
  trace = 0.d0
  do i = 1, nbasis
  trace = trace + abs(rho_srb(spin)%dat(i,i))
  enddo
  write(*,*) "Trace(rho) = ", trace
  call start_clock('  svd')
  call diag(rho_srb(spin), S, sv)
  call stop_clock('  svd')
  S = abs(S)
  trace = sum(S)
  write(*,*) "Trace(rho) = ", trace
  max_band = 1
  do ibnd = 1, nbasis
      if (S(nbasis+1-ibnd)*(nbasis+1.-ibnd)/trace < W_TOL) exit
      max_band = ibnd
  enddo
  if (me_image == 0) write(*,*) max_band, " of ", nbasis

  ! transform the representative wave-functions to <G|
  allocate(tmp(npw, max_band))
  call start_clock('  gemm')
  call ZGEMM('N', 'N', npw, max_band, nbasis, one, &
              opt_basis%elements, npw, &
              sv%dat(:,nbasis+1-max_band), nbasis, zero, &
              tmp, npw)
  call stop_clock('  gemm')

  ! accumulate the left singular vectors
  do ibnd = 1, max_band
    psic(:) = ( 0.D0, 0.D0 )

!    call save_buffer(rho_srb(:,nbasis-max_band + ibnd, spin), nbasis, funit+1, ibnd)
    ! Transform <G|u> to <r|u>
    call start_clock('  fft')
    psic(nls(igk(1:npw))) = tmp(1:npw, ibnd)
    CALL invfft ('Wave', psic, dffts)
    call stop_clock('  fft')

!    call save_buffer(psic, dffts%nnr, funit, ibnd)

    ! Accumulate |<r|u>|^2 with weights
    call start_clock('  acc')
    do ir = 1, dffts%nnr
      rho%of_r(ir, spin) = rho%of_r(ir, spin) + S(nbasis-max_band+ibnd) * (DBLE(psic(ir))**2 + AIMAG(psic(ir))**2)
    enddo
    call stop_clock('  acc')
  enddo
  decomp_size = max_band

  deallocate(tmp)
  enddo 
  deallocate(S, igk, g2kin)

  return

end subroutine transform_rho
