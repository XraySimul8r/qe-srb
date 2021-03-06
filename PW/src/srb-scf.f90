!----------------------------------------------------------------------------
SUBROUTINE srb_scf(evc, V_rs, rho, eband, demet, sc_error, skip)
!----------------------------------------------------------------------------
!
! Authors: Max Hutchinson, David Prendergast, PWSCF
! 
! ... calculates the symmetrized charge density using a srb interpolation scheme 
!
!
!#define SCUDA
!#define DEBUG

  USE ISO_C_BINDING,        ONLY : c_ptr, C_NULL_PTR

  USE kinds,                ONLY : DP
  USE klist,                ONLY : nelec, lgauss, nks, nkstot, wk, xk
  USE control_flags,        ONLY : io_level 
  USE gvect,                ONLY : nl
  USE wavefunctions_module, ONLY : psic
  USE fft_base,             ONLY : dfftp
  USE gvecs,                ONLY : doublegrid
  USE funct,                ONLY : dft_is_meta
  USE io_global,            ONLY : stdout
  use uspp,                 only : nkb, okvan, becsum
  USE lsda_mod,             only : nspin, isk
  use wvfct,                only : wg, et

  USE srb_types,        ONLY : basis, ham_expansion, pseudop, nk_list, kproblem
  USE srb_matrix,       ONLY : setup_dmat, dmat, copy_dmat
  use srb_matrix,       only : pot_scope, pool_scope
  USE srb,              ONLY : qpoints, basis_life, freeze_basis
  USE srb,              ONLY : use_cuda, rho_reduced 
  use srb,              ONLY : states, bstates, wgq, red_basis=>scb, ets, pp=>spp
  USE srb, ONLY : build_basis, build_basis_cuda, build_h_coeff, build_h_matrix, diagonalize, build_rho
  USE srb, ONLY : build_h_coeff_cuda
  USE srb, ONLY : build_projs_reduced, load_projs, copy_pseudo_cuda, build_projs_cuda, build_s_matrix, store_states
  use srb, only : solve_system_cuda
  use srb, only : build_rho_reduced, transform_rho, backload
  USE scf,                  ONLY : scf_type
  USE fft_types,            ONLY : fft_dlay_descriptor
  USE fft_interfaces,       ONLY : invfft, fwfft
  USE symme,                ONLY : sym_rho
  use mp, only : mp_sum
  use mp_global, only : intra_pool_comm, me_pool, nproc_pool, me_image
  use mp_global, only : me_pot, nproc_pot, npot, my_pot_id, inter_pot_comm
  use scalapack_mod, only : scalapack_distrib, scalapack_blocksize
  use buffers, only : get_buffer

  !
  IMPLICIT NONE
  !
  ! ... arguments (yes, fortran allows arguments)
  !
  COMPLEX(DP),    INTENT(IN)  :: evc(:,:)   !>!< wavefunctions in PW basis
  REAL(DP),       INTENT(IN)  :: V_rs(:,:)  !>!< total potential in real space
  TYPE(scf_type), INTENT(INOUT) :: rho        !>!< electron density (and some other stuff)
  real(DP),       INTENT(OUT) :: eband      !>!< band contribution to energy
  real(DP),       INTENT(OUT) :: demet      !>!< ??? contribution to energy
  real(DP),       INTENT(IN) :: sc_error
  logical,        INTENT(OUT) :: skip
  ! Interfaces
  interface
    SUBROUTINE weights(nks, nkstot, wk, xk, et, wg, eband)
      USE kinds,                ONLY : DP
      integer, intent(in) :: nks, nkstot
      real(DP), intent(in) :: wk(:)
      real(DP), intent(in) :: xk(:,:)
      real(DP), intent(in) :: et(:,:)
      real(DP), intent(out) :: wg(:,:)
      real(DP), intent(out) :: eband
    end subroutine weights
    subroutine addusdens_g(bar, foo)
      use kinds, only : DP
      real(DP), intent(inout) :: bar(:,:,:)
      real(DP), intent(inout) :: foo(:,:)
    end subroutine addusdens_g
  end interface
  !
  ! ... local variables
  !
  TYPE(ham_expansion), save :: h_coeff !>!< Expansion of Hamiltonian wrt k
  TYPE(kproblem)            :: Hk !>!< Hamiltonain at a specific kpoint
  real(DP), allocatable, target ::  energies(:,:) !>!< eigen-values (energies)
  type(dmat) :: evecs !>!< eigenvectors of Hamiltonian
  type(dmat), allocatable :: rho_srb(:) !>!< Denstiy matrix in reduced basis
  real(DP), allocatable :: wr2(:), xr2(:,:) !>!< copies of k-points and weights
  ! parameters
  integer, save :: basis_age = -1, itr_count = 0
  integer :: nbnd
  real(DP), save :: ecut_srb
  integer :: meth
  ! tmps and workspace
  complex(DP) :: ztmp
  INTEGER :: i, j, k, q, s
  integer :: nblock, info
  complex(DP), pointer :: ptr(:,:) => NULL()
  integer, allocatable :: ipiv(:)
  complex(DP), allocatable :: work(:)

#ifdef SCUDA
  if (use_cuda) call setup_cuda()
  write(*,*) "setup cuda"
#endif

  ! Checks, checks, checks
  if ( dft_is_meta() ) then
    write(*,*) "Shirley for meta DFT not yet supported "
  end if

  call start_clock( 'srb')
  call start_clock(  ' other')

  ! inits
  nbnd = size(evc, 2)
  states%nbnd  = nbnd
  bstates%nbnd = nbnd

  !
  ! ... Do a basis calculation
  !
  if (basis_age >= basis_life - 1 .and. sc_error > freeze_basis) then
    basis_age = -1
    deallocate(red_basis%elements)
    if (allocated(red_basis%elem_rs)) deallocate(red_basis%elem_rs)
    deallocate(h_coeff%lin)
    red_basis%length = -1
  endif

  call stop_clock(  ' other')
  if (basis_age == -1) then
    call start_clock( ' build_red_basis' )
    call build_basis(evc, red_basis, ecut_srb)
    call stop_clock( ' build_red_basis' )
    if (.not. allocated(h_coeff%con)) allocate(h_coeff%con(nspin))
    do s = 1,nspin
      call setup_dmat(h_coeff%con(s), red_basis%length, red_basis%length, scope_in = pot_scope)
    enddo
    call setup_dmat(h_coeff%kin_con, red_basis%length, red_basis%length, scope_in = pot_scope)
  else
    if (me_image == 0) write(*,'(5X,A,I5,A,I3)') "Using a basis of length ", red_basis%length, " and age ", basis_age
  endif
  basis_age = basis_age + 1
  skip = ((basis_age < basis_life - 1) .or. sc_error <  freeze_Basis)

  !
  ! ... Construct the local Hamiltonian
  ! 
  call start_clock( ' build_h_coeff' )
  call build_h_coeff(red_basis, V_rs(:,:), ecut_srb, nspin, h_coeff, basis_age /= 0)
  call stop_clock( ' build_h_coeff' )
  call start_clock(  ' other')

  !
  ! ... Setup dense data structures
  !
  call setup_dmat(evecs, red_basis%length, nbnd, red_basis%length, min(16,nbnd/nproc_pot), pot_scope)
  if (allocated(energies)) deallocate(energies)
  allocate(energies(red_basis%length, nspin*qpoints%nred))
  energies = 0.d0

  states%nk = qpoints%nred * nspin
  call setup_dmat(Hk%H, red_basis%length, red_basis%length, scope_in = pot_scope)
  if (okvan) then
    call copy_dmat(Hk%S, Hk%H)
    pp%us = .true.
    Hk%generalized = .true.
    bstates%nk = qpoints%nred * nspin
  else
    bstates%nk = 0
  end if

  ! Swapping is controled by the disk_io input param
  ! setting 3rd dim to size 1 signals code to swap each k-point
  if (associated(states%host_ar)) deallocate(states%host_ar)
  if (associated(bstates%host_ar)) deallocate(bstates%host_ar)
  if (io_level < 1) then
    allocate(states%host_ar(states%nk+npot))
    do q = 1,states%nk+npot
      call copy_dmat(states%host_ar(q), evecs)
    enddo
    if (bstates%nk == 0) then 
      allocate(bstates%host_ar(0))
    else 
      allocate(bstates%host_ar(bstates%nk+npot))
      call setup_dmat(bstates%host_ar(1), nkb, nbnd, nkb, min(16,nbnd/nproc_pot), pot_scope)
      do q = 2,states%nk+npot
        call copy_dmat(bstates%host_ar(q), bstates%host_ar(1))
      enddo
    endif
  else
    allocate(states%host_ar(1))
    call setup_dmat(states%host_ar(1), red_basis%length, nbnd, red_basis%length,min(16,nbnd), pot_scope)
    if (bstates%nk == 0) then 
      allocate(bstates%host_ar(0))
    else
      allocate(bstates%host_ar(1))
      call setup_dmat(bstates%host_ar(1), nkb, nbnd, nkb, min(16,nbnd/nproc_pot), pot_scope)
    endif
  endif

  !
  ! ... Transform projectors
  !
  call stop_clock(  ' other')
  if (nkb > 0 .and. basis_age == 0) then
    call start_clock(' build_proj')
    call build_projs_reduced(red_basis, qpoints%xr(:,:), qpoints%nred, pp)
    call stop_clock(' build_proj')
  endif

  !
  ! ... main q-point loop
  !
  do q = 1+my_pot_id, qpoints%nred, npot
    !
    ! ... Build dense S matrix 
    !
    call start_clock( '  proj_load')
    if (nkb > 0) then
      call load_projs(q, pp)
    endif
    call stop_clock(  '  proj_load')

    if (okvan) then
      CALL start_clock(' build_mat' )
      if (basis_age == 0) then
        call build_s_matrix(pp, (1-q)/npot - 1, Hk)
      else
        call build_s_matrix(pp, (q-1)/npot + 1, Hk)
      endif
      CALL stop_clock(' build_mat' )
    end if

    ! loop over spins (which share S matrices)
    do s = 1, nspin
        !
        ! ... Build dense Hamiltonian matrix
        !
        CALL start_clock(' build_mat' )
        if (basis_age == 0) then
          call build_h_matrix(h_coeff, qpoints%xr(:,q), pp, s, Hk, (1-q)/npot-1)
        else
          call build_h_matrix(h_coeff, qpoints%xr(:,q), pp, s, Hk, (q-1)/npot+1)
        endif
        CALL stop_clock(' build_mat' )

        ! 
        ! ... Diagonalize the dense Hamiltonian 
        !
        CALL start_clock( ' diagonalize' )
        if (okvan) then
          Hk%generalized = .true.
          call diagonalize(Hk, energies(:,q+(s-1)*qpoints%nred), evecs, &
                           nbnd, meth_opt = meth)
        else
          Hk%generalized = .false.
          call diagonalize(Hk, energies(:,q+(s-1)*qpoints%nred), evecs,  &
                           nbnd, meth_opt = meth)
        end if
        CALL stop_clock( ' diagonalize' )

        !
        ! ... Compute <\b|psi> and store it and <b|psi>
        !
        CALL start_clock( ' store' )
        call store_states(evecs, pp, (q+(s-1)*(qpoints%nred+npot)-1)/npot + 1, states, bstates)
        CALL stop_clock( ' store' )
    enddo 
  enddo 
  call start_clock(  ' other')
  call mp_sum(energies, inter_pot_comm)
  call stop_clock(  ' other')
  CALL start_clock( ' build_rho' )

  !
  ! ... make new weights
  !
  if (associated(wgq)) deallocate(wgq)
  nullify(wgq); allocate(wgq(red_basis%length, nspin*qpoints%nred))
  allocate(wr2(nspin * qpoints%nred), xr2(3, nspin*qpoints%nred))
  do s = 0, nspin-1
    wr2(1+s*qpoints%nred:qpoints%nred + s*qpoints%nred) = qpoints%wr(1:qpoints%nred) / nspin
    xr2(:,1+s*qpoints%nred:qpoints%nred + s*qpoints%nred) = qpoints%xr(:,1:qpoints%nred)
  enddo
  call weights(qpoints%nred*nspin, qpoints%nred*nspin, wr2, xr2, energies(1:nbnd,:), wgq(1:nbnd,:), demet)
  deallocate(wr2, xr2)

#ifdef DEBUG
  if( nspin==2 .and. me_image == 0 ) then
    write(*,*) "sum(weights): ", sum(wgq(1:nbnd,1:qpoints%nred)), sum(wgq(1:nbnd,qpoints%nred+1:2*qpoints%nred))
  else if( nspin==1 .and. me_image == 0 ) then
    write(*,*) "sum(weights): ", sum(wgq(1:nbnd,1:qpoints%nred))
  endif
#endif

  eband = sum(energies(1:nbnd, :) * wgq(1:nbnd, :)) 
  ets = energies(1:nbnd, :)

  !
  ! ...  Build the density <r|\rho|r>
  !
  rho%of_r(:,:) = 0.D0; rho%of_g(:,:) = 0.D0; becsum = 0.d0
  if (rho_reduced) then
    allocate(rho_srb(nspin))
    call setup_dmat(rho_srb(1), red_basis%length, red_basis%length, scope_in = pot_scope)
    if (nspin == 2) call copy_dmat(rho_srb(2), rho_srb(1))
    ! Build reduced density matrix <b|\rho|b'>
    call start_clock( '  reduced')
    call build_rho_reduced(states, bstates, wgq(:,:), qpoints%wr(:) / nspin, nspin, rho_srb, becsum)
    call stop_clock( '  reduced')
    ! Take SVD of \rho and transform to <r|\rho|r>
    call start_clock( '  trans')
    call transform_rho(rho_srb, red_basis, rho)
    call stop_clock( '  trans')
    deallocate(rho_srb)
  else
    ! Go straight to real-space (bad idea)
    call build_rho(states, bstates, wgq(:,:), qpoints%wr(:) / nspin, red_basis, nspin, rho, becsum)
  endif
  CALL stop_clock( ' build_rho' )
  call start_clock(  ' finish_rho')

  ! ... interpolate rho(r) if needed
  if (doublegrid) then
    do s = 1, nspin
      CALL interpolate(rho%of_r(1,s), rho%of_r(1,s), 1)
    enddo
  endif

  ! ... add ultra-soft correction
  if (okvan) call addusdens_g(becsum, rho%of_r)

  ! ... symmetrize rho(G) 
#if 1
  do s = 1, nspin
    psic(:) = rho%of_r(:,s)
    CALL fwfft ('Dense', psic, dfftp)
    rho%of_g(:,s) = psic(nl(:))
  enddo
  CALL sym_rho ( nspin, rho%of_g )
  do s = 1, nspin
    psic(:) = ( 0.D0, 0.D0 )
    psic(nl(:)) = rho%of_g(:,s)
    CALL invfft ('Dense', psic, dfftp)
    rho%of_r(:,s) = psic(:)
  enddo
#endif
  itr_count = itr_count + 1
#if 0
  if (.not. skip) then
    call backload(qpoints, red_basis, states)
  endif
#endif

  call stop_clock(  ' finish_rho')
  call stop_clock('srb')

  return

end subroutine srb_scf

