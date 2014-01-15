!
! Copyright (C) 2001-2003 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!
!----------------------------------------------------------------------------
SUBROUTINE stress_us_srb( ik_, gk, sigmanlc )
  !----------------------------------------------------------------------------
  !
  ! nonlocal (separable pseudopotential) contribution to the stress
  !
  USE kinds,                ONLY : DP
  USE ions_base,            ONLY : nat, ntyp => nsp, ityp
  USE constants,            ONLY : eps8
  USE klist,                ONLY : nks, xk
  USE lsda_mod,             ONLY : current_spin, lsda, isk, nspin
  USE wvfct,                ONLY : npw, npwx, igk, wg, et
  USE control_flags,        ONLY : gamma_only
  USE uspp_param,           ONLY : upf, lmaxkb, nh, newpseudo, nhm
  USE uspp,                 ONLY : nkb, vkb, qq, deeq, deeq_nc, qq_so
  USE wavefunctions_module, ONLY : evc
  USE spin_orb,             ONLY : lspinorb
  USE lsda_mod,             ONLY : nspin
  USE noncollin_module,     ONLY : noncolin, npol
  USE mp_global,            ONLY : me_pool, root_pool, intra_bgrp_comm,inter_bgrp_comm
  USE becmod,               ONLY : allocate_bec_type, deallocate_bec_type, &
                                   bec_type, becp, calbec
  USE mp,                   ONLY : mp_sum, mp_get_comm_null, mp_circular_shift_left 
  !
  IMPLICIT NONE
  !
  ! ... First the dummy variables
  !  
  INTEGER       :: ik_
  REAL(DP) :: sigmanlc(3,3), gk(3,npw)
  integer :: ik
  !
!  CALL allocate_bec_type ( nkb, nbnd, becp, intra_bgrp_comm ) 
  
  !
  IF ( gamma_only ) THEN
     !
     CALL stress_us_gamma_srb()
     !
  ELSE
     !
     CALL stress_us_k_srb()
     !
  END IF
  !
!  CALL deallocate_bec_type ( becp ) 
  !
  RETURN
  !
  CONTAINS
     !
     !-----------------------------------------------------------------------
     SUBROUTINE stress_us_gamma_srb()
       !-----------------------------------------------------------------------
       ! 
       ! ... gamma version
       !
       USE wvfct,                ONLY :  nbnd
       IMPLICIT NONE
       !
       ! ... local variables
       !
       INTEGER                       :: na, np, ibnd, ipol, jpol, l, i, &
                                        ikb, jkb, ih, jh, ijkb0, ibnd_loc, &
                                        nproc, mype, nbnd_loc, nbnd_begin, &
                                        nbnd_max, icur_blk, icyc, ibnd_begin, &
                                        nbands
       INTEGER, EXTERNAL :: ldim_block, lind_block, gind_block
       REAL(DP)                 :: fac, xyz(3,3), q, evps, ddot
       REAL(DP), ALLOCATABLE    :: qm1(:)
       COMPLEX(DP), ALLOCATABLE :: work1(:), work2(:), dvkb(:,:)
       ! dvkb contains the derivatives of the kb potential
       COMPLEX(DP)              :: ps
       ! xyz are the three unit vectors in the x,y,z directions
       DATA xyz / 1.0d0, 0.0d0, 0.0d0, 0.0d0, 1.0d0, 0.0d0, 0.0d0, 0.0d0, 1.0d0 /
       !
       !
       IF ( nkb == 0 ) RETURN
       IF( becp%comm /= mp_get_comm_null() ) THEN
          nproc   = becp%nproc
          mype    = becp%mype
          nbnd_loc   = becp%nbnd_loc
          nbnd_begin = becp%ibnd_begin
          nbnd_max   = SIZE(becp%r,2)
          nbands = nbnd_loc
          
          IF( ( nbnd_begin + nbnd_loc - 1 ) > nbnd ) nbnd_loc = nbnd - nbnd_begin + 1
       ELSE
          nproc = 1
          nbnd_loc = nbnd
          nbnd_begin = 1
          nbnd_max = SIZE(becp%r,2)
          nbands = nbnd 
       END IF

       IF ( lsda ) current_spin = isk(ik)
       IF ( nks > 1 ) CALL init_us_2( npw, igk, xk(1,ik), vkb )
       !
       CALL calbec( npw, vkb, evc, becp )
       !
       ALLOCATE( work1( npwx ), work2( npwx ), qm1( npwx )) 
       !
       DO i = 1, npw
          q = SQRT( gk(1,i)**2 + gk(2,i)**2 + gk(3,i)**2 )
          IF ( q > eps8 ) THEN
             qm1(i) = 1.D0 / q
          ELSE
             qm1(i) = 0.D0
          END IF
       END DO
       !
       ! ... diagonal contribution
       !
       evps = 0.D0
       !
       IF ( me_pool /= root_pool ) GO TO 100
 
          
       DO ibnd_loc = 1, nbands
          ibnd = ibnd_loc + becp%ibnd_begin - 1 
          fac = wg(ibnd,ik)
          ijkb0 = 0
          DO np = 1, ntyp
             DO na = 1, nat
                IF ( ityp(na) == np ) THEN
                   DO ih = 1, nh(np)
                      ikb = ijkb0 + ih
                      ps = deeq(ih,ih,na,current_spin) - &
                           et(ibnd,ik) * qq(ih,ih,np)
                      evps = evps + fac * ps * ABS( becp%r(ikb,ibnd_loc) )**2
                      !
                      IF ( upf(np)%tvanp .OR. newpseudo(np) ) THEN
                         !
                         ! ... only in the US case there is a contribution 
                         ! ... for jh<>ih
                         ! ... we use here the symmetry in the interchange of 
                            ! ... ih and jh
                         !
                         DO jh = ( ih + 1 ), nh(np)
                            jkb = ijkb0 + jh
                            ps = deeq(ih,jh,na,current_spin) - &
                                 et(ibnd,ik) * qq(ih,jh,np)
                            evps = evps + ps * fac * 2.D0 * &
                                 becp%r(ikb,ibnd_loc) * becp%r(jkb,ibnd_loc)
                         END DO
                      END IF
                   END DO
                   ijkb0 = ijkb0 + nh(np)
                END IF
             END DO
          END DO
       END DO    
      
100    CONTINUE
      
       !
       ! ... non diagonal contribution - derivative of the bessel function
       !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       ALLOCATE( dvkb( npwx, nkb ) )
       !
       CALL gen_us_dj(npw, igk, xk(:,ik), dvkb )
       !
       ibnd_begin = becp%ibnd_begin 
       
       DO icyc = 0, nproc -1
          
          
          DO ibnd_loc = 1, nbands
             
             ibnd = ibnd_loc + ibnd_begin - 1 
             work2(:) = (0.D0,0.D0)
             ijkb0 = 0
             DO np = 1, ntyp
                DO na = 1, nat
                   IF ( ityp(na) == np ) THEN
                      DO ih = 1, nh(np)
                         ikb = ijkb0 + ih
                         IF ( .NOT. ( upf(np)%tvanp .OR. newpseudo(np) ) ) THEN
                            ps = becp%r(ikb,ibnd_loc) * &
                                 ( deeq(ih,ih,na,current_spin) - &
                                 et(ibnd,ik) * qq(ih,ih,np) )
                         ELSE
                            !
                            ! ... in the US case there is a contribution 
                            ! ... also for jh<>ih
                            !
                            ps = (0.D0,0.D0)
                            DO jh = 1, nh(np)
                               jkb = ijkb0 + jh
                               ps = ps + becp%r(jkb,ibnd_loc) * &
                                    ( deeq(ih,jh,na,current_spin) - &
                                    et(ibnd,ik) * qq(ih,jh,np) )
                            END DO
                         END IF
                         CALL zaxpy( npw, ps, dvkb(1,ikb), 1, work2, 1 )
                      END DO
                      ijkb0 = ijkb0 + nh(np)
                   END IF
                END DO
             END DO
             !
             ! ... a factor 2 accounts for the other half of the G-vector sphere
             !
             DO ipol = 1, 3
                DO jpol = 1, ipol
                   DO i = 1, npw
                      work1(i) = evc(i,ibnd) * gk(ipol,i) * gk(jpol,i) * qm1(i)
                   END DO
                   sigmanlc(ipol,jpol) = sigmanlc(ipol,jpol) - &
                        4.D0 * wg(ibnd,ik) * &
                        ddot( 2 * npw, work1, 1, work2, 1 )
                END DO
             END DO
          END DO
          IF(nproc>1)then
             call mp_circular_shift_left(becp%r, icyc, becp%comm)
             call mp_circular_shift_left(ibnd_begin, icyc, becp%comm)
          END IF
       END DO
       
       !
       ! ... non diagonal contribution - derivative of the spherical harmonics
       ! ... (no contribution from l=0)
       !
       IF ( lmaxkb == 0 ) GO TO 10
       !
       !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
       DO ipol = 1, 3
          CALL gen_us_dy(npw, igk, xk(:,ik), xyz(1,ipol), dvkb )
             icur_blk = mype
             ibnd_begin = becp%ibnd_begin 
             DO icyc = 0, nproc -1
               
                DO ibnd_loc = 1, nbands
                   ibnd = ibnd_loc + ibnd_begin - 1 
                   work2(:) = (0.D0,0.D0)
                   ijkb0 = 0
                   DO np = 1, ntyp
                      DO na = 1, nat
                         IF ( ityp(na) == np ) THEN
                            DO ih = 1, nh(np)
                               ikb = ijkb0 + ih
                               IF ( .NOT. ( upf(np)%tvanp .OR. newpseudo(np) ) ) THEN
                                  ps = becp%r(ikb,ibnd_loc) * &
                                          ( deeq(ih,ih,na,current_spin) - &
                                          et(ibnd,ik) * qq(ih,ih,np ) )
                               ELSE 
                                  !
                                  ! ... in the US case there is a contribution 
                                  ! ... also for jh<>ih
                                  !
                                  ps = (0.D0,0.D0)
                                  DO jh = 1, nh(np)
                                     jkb = ijkb0 + jh
                                     ps = ps + becp%r(jkb,ibnd_loc) * &
                                          ( deeq(ih,jh,na,current_spin) - &
                                          et(ibnd,ik) * qq(ih,jh,np) )
                                  END DO
                               END IF
                               CALL zaxpy( npw, ps, dvkb(1,ikb), 1, work2, 1 )
                            END DO
                            ijkb0 = ijkb0 + nh(np)
                         END IF
                      END DO
                   END DO
                   !
                   ! ... a factor 2 accounts for the other half of the G-vector sphere
                   !
                   DO jpol = 1, ipol
                      DO i = 1, npw
                         work1(i) = evc(i,ibnd) * gk(jpol,i)
                      END DO
                      sigmanlc(ipol,jpol) = sigmanlc(ipol,jpol) - &
                           4.D0 * wg(ibnd,ik) * &
                           ddot( 2 * npw, work1, 1, work2, 1 )
                   END DO
                END DO


                if(nproc>1)then
                   call mp_circular_shift_left(becp%r, icyc, becp%comm)
                   call mp_circular_shift_left(ibnd_begin, icyc, becp%comm)
                end if
                

             ENDDO
       END DO

10     CONTINUE
       !
       DO l = 1, 3
          sigmanlc(l,l) = sigmanlc(l,l) - evps
       END DO
       !
       DEALLOCATE( dvkb )
       DEALLOCATE( qm1, work2, work1 )
       !
       RETURN
       !
     END SUBROUTINE stress_us_gamma_srb     
     !
     !
     !----------------------------------------------------------------------
     SUBROUTINE stress_us_k_srb()
       !----------------------------------------------------------------------  
       !
       ! ... k-points version
       !
       use srb, only : qpoints, states, bstates, wgq, scb, ets
       use cell_base, only : bg
       use mp_global, only : root_pot, my_pot_id, me_image
       IMPLICIT NONE
       !
       ! ... local variables
       !
       INTEGER                       :: na, np, ibnd, ipol, jpol, l, i, &
                                        ikb, jkb, ih, jh, ijkb0, is, js, ijs
       REAL(DP)                 :: fac, xyz (3, 3), q, evps, ddot
       REAL(DP), ALLOCATABLE    :: qm1(:)
       COMPLEX(DP), ALLOCATABLE :: work1(:), work2(:), dvkb(:,:)
       COMPLEX(DP), ALLOCATABLE :: work2_nc(:,:)
       COMPLEX(DP), ALLOCATABLE :: deff_nc(:,:,:,:)
       REAL(DP), ALLOCATABLE :: deff(:,:,:)
       ! dvkb contains the derivatives of the kb potential
       COMPLEX(DP)              :: ps, ps_nc(2)
       integer :: nbnd
       integer, external :: indxl2g
       ! xyz are the three unit vectors in the x,y,z directions
       DATA xyz / 1.0d0, 0.0d0, 0.0d0, 0.0d0, 1.0d0, 0.0d0, 0.0d0, 0.0d0, 1.0d0 /
       !
       !
       IF ( nkb == 0 ) RETURN
       !
       current_spin = (ik_-1)/qpoints%nred + 1
       ik = ik_ - (current_spin-1)*qpoints%nred
       npw = size(scb%elements, 1)
       nbnd = size(becp%k,2)
       if (noncolin) then
          ALLOCATE( work2_nc(npwx,npol) )
          ALLOCATE( deff_nc(nhm,nhm,nat,nspin) )
       else
          ALLOCATE( deff(nhm,nhm,nat) )
       endif
       !
       ALLOCATE( work1(npwx), work2(npwx), qm1( npwx ) )
       !
       DO i = 1, npw
          q = SQRT( gk(1,i)**2 + gk(2,i)**2 + gk(3,i)**2 )
          IF ( q > eps8 ) THEN
             qm1(i) = 1.D0 / q
          ELSE
             qm1(i) = 0.D0
          END IF
       END DO
       !
       evps = 0.D0
       ! ... diagonal contribution
       !
       IF ( me_image /= 0 ) GO TO 100
       !
       ! ... the contribution is calculated only on one processor because
       ! ... partial results are later summed over all processors
       !
       DO ibnd = 1, nbnd
          fac = wgq(ibnd,ik_)
          IF (ABS(fac) < 1.d-9) CYCLE
          IF (noncolin) THEN
             CALL compute_deff_nc(deff_nc,ets(ibnd,ik_))
          ELSE
             CALL compute_deff(deff,ets(ibnd,ik_))
          ENDIF
          ijkb0 = 0
          DO np = 1, ntyp
             DO na = 1, nat
                IF ( ityp(na) == np ) THEN
                   DO ih = 1, nh(np)
                      ikb = ijkb0 + ih
                         evps = evps+fac*deff(ih,ih,na)*ABS(becp%k(ikb,ibnd) )**2
                      !
                      IF ( upf(np)%tvanp .OR. newpseudo(np) ) THEN
                         !
                         ! ... only in the US case there is a contribution 
                         ! ... for jh<>ih
                         ! ... we use here the symmetry in the interchange of 
                         ! ... ih and jh
                         !
                         DO jh = ( ih + 1 ), nh(np)
                            jkb = ijkb0 + jh
                               evps = evps + deff(ih,jh,na) * fac * 2.D0 * &
                                     DBLE( CONJG( becp%k(ikb,ibnd) ) * &
                                                  becp%k(jkb,ibnd) )
                         END DO
                      END IF
                   END DO
                   ijkb0 = ijkb0 + nh(np)
                END IF
             END DO
          END DO
       END DO
       DO l = 1, 3
          sigmanlc(l,l) = sigmanlc(l,l) - evps
       END DO
       !
100    CONTINUE
       !
       ! ... non diagonal contribution - derivative of the bessel function
       !
       ALLOCATE( dvkb( npwx, nkb ) )
       !
       CALL gen_us_dj(npw, igk, matmul( bg, qpoints%xr(:,ik) - floor(qpoints%xr(:,ik))), dvkb )
       !
       DO ibnd = 1, nbnd
          IF (noncolin) THEN
             work2_nc = (0.D0,0.D0)
             CALL compute_deff_nc(deff_nc,ets(ibnd,ik_))
          ELSE
             work2 = (0.D0,0.D0)
             CALL compute_deff(deff,ets(ibnd,ik_))
          ENDIF
          ijkb0 = 0
          DO np = 1, ntyp
             DO na = 1, nat
                IF ( ityp(na) == np ) THEN
                   DO ih = 1, nh(np)
                      ikb = ijkb0 + ih
                      IF ( .NOT. ( upf(np)%tvanp .OR. newpseudo(np) ) ) THEN
                            ps = becp%k(ikb, ibnd) * deeq(ih,ih,na,current_spin)
                      ELSE
                         !
                         ! ... in the US case there is a contribution 
                         ! ... also for jh<>ih
                         !
                         ps = (0.D0,0.D0)
                         ps_nc = (0.D0,0.D0)
                         DO jh = 1, nh(np)
                            jkb = ijkb0 + jh
                               ps = ps + becp%k(jkb,ibnd) * deff(ih,jh,na)
                         END DO
                      END IF
                         CALL zaxpy( npw, ps, dvkb(1,ikb), 1, work2, 1 )
                   END DO
                   ijkb0 = ijkb0 + nh(np)
                END IF
             END DO
          END DO
          DO ipol = 1, 3
             DO jpol = 1, ipol
                   DO i = 1, npw
                      work1(i) = evc(i,ibnd)*gk(ipol,i)*gk(jpol,i)*qm1(i)
                   END DO
                   sigmanlc(ipol,jpol) = sigmanlc(ipol,jpol) - &
                                      2.D0 * wgq(ibnd,ik_) * &
                                      ddot( 2 * npw, work1, 1, work2, 1 )
             END DO
          END DO
       END DO
       !
       ! ... non diagonal contribution - derivative of the spherical harmonics
       ! ... (no contribution from l=0)
       !
       IF ( lmaxkb == 0 ) GO TO 10
       !
       DO ipol = 1, 3
          CALL gen_us_dy(npw, igk, matmul( bg, qpoints%xr(:,ik) - floor(qpoints%xr(:,ik))), xyz(1,ipol), dvkb )
          DO ibnd = 1, nbnd
             IF (noncolin) THEN
                work2_nc = (0.D0,0.D0)
                CALL compute_deff_nc(deff_nc,ets(ibnd,ik_))
             ELSE
                work2 = (0.D0,0.D0)
                CALL compute_deff(deff,ets(ibnd,ik_))
             ENDIF

             ijkb0 = 0
             DO np = 1, ntyp
                DO na = 1, nat
                   IF ( ityp(na) == np ) THEN
                      DO ih = 1, nh(np)
                         ikb = ijkb0 + ih
                         IF ( .NOT. ( upf(np)%tvanp .OR. newpseudo(np) ) ) THEN
                               ps = becp%k(ikb,ibnd) * deeq(ih,ih,na,current_spin)
                         ELSE
                            !
                            ! ... in the US case there is a contribution 
                            ! ... also for jh<>ih
                            !
                            ps = (0.D0,0.D0)
                            ps_nc = (0.D0,0.D0)
                            DO jh = 1, nh(np)
                               jkb = ijkb0 + jh
                                  ps = ps + becp%k(jkb,ibnd) * deff(ih,jh,na)
                            END DO
                         END IF
                            CALL zaxpy( npw, ps, dvkb(1,ikb), 1, work2, 1 )
                      END DO
                      ijkb0 = ijkb0 + nh(np)
                   END IF
                END DO
             END DO
             DO jpol = 1, ipol
                   DO i = 1, npw
                      work1(i) = evc(i,ibnd) * gk(jpol,i)
                   END DO
                   sigmanlc(ipol,jpol) = sigmanlc(ipol,jpol) - &
                                      2.D0 * wgq(ibnd,ik_) * & 
                                      ddot( 2 * npw, work1, 1, work2, 1 )
             END DO
          END DO
       END DO
       !
10     CONTINUE
       !
       IF (noncolin) THEN
           DEALLOCATE( work2_nc )
           DEALLOCATE( deff_nc )
       ELSE
           DEALLOCATE( work2 )
           DEALLOCATE( deff )
       ENDIF
       DEALLOCATE( dvkb )
       DEALLOCATE( work1, qm1 )
       !
       RETURN
       !
     END SUBROUTINE stress_us_k_srb
     !
END SUBROUTINE stress_us_srb
