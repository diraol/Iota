package Iota::Controller::Web;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller' }
use utf8;
use JSON::XS;
use Iota::Statistics::Frequency;
use I18N::AcceptLanguage;
use DateTime;

#
# Sets the actions in this controller to be registered with no prefix
# so they function identically to actions created in MyApp.pm
#
__PACKAGE__->config( namespace => '' );

has 'lang_acceptor' => (
    is      => 'rw',
    isa     => 'I18N::AcceptLanguage',
    lazy    => 1,
    default => sub { I18N::AcceptLanguage->new( defaultLanguage => 'pt-br' ) }
);

sub change_lang : Chained('root') PathPart('lang') CaptureArgs(1) {
    my ( $self, $c, $lang ) = @_;
    $c->stash->{lang} = $lang;
}

sub change_lang_redir : Chained('change_lang') PathPart('') Args(0) {
    my ( $self, $c ) = @_;

    my $cur_lang = $c->stash->{lang};
    my %langs = map { $_ => 1 } split /,/, $c->config->{available_langs};
    $cur_lang = 'pt-br' unless exists $langs{$cur_lang};
    my $host = $c->req->uri->host;

    $c->response->cookies->{'cur_lang'} = {
        value   => $cur_lang,
        path    => '/',
        expires => '+3600h',
    };

    my $refer = $c->req->headers->referer;
    if ( $refer && $refer =~ /^http:\/\/$host/ ) {
        $c->res->redirect($refer);
    }
    else {
        $c->res->redirect( $c->uri_for('/') );
    }
    $c->detach;
}

sub light_institute_load : Chained('root') PathPart('') CaptureArgs(0) {
    my ( $self, $c ) = @_;

    # se veio ?part, guarda na stash e remove ele da req para nao atrapalhar novas geracoes de URLs
    $c->stash->{current_part} = delete $c->req->params->{part};
    if ( $c->stash->{current_part} ) {
        delete $c->req->{query_parameters}{part};
        $c->req->uri( $c->req->uri_with( { part => undef } ) );
    }

    my $domain = $c->req->uri->host;
    my $net    = $c->model('DB::Network')->search(
        { domain_name => $domain },
        {
            join     => 'institute',
            collapse => 1,
            columns  => [
                qw/
                  me.id
                  me.name
                  me.name_url
                  me.ga_account
                  me.domain_name

                  institute.id
                  institute.name
                  institute.short_name
                  institute.bypass_indicator_axis_if_custom
                  institute.hide_empty_indicators
                  /
            ]
        }
    )->first;

    # gambiarra pra ter rede nos testes..
    if ( exists $ENV{HARNESS_ACTIVE} && $ENV{HARNESS_ACTIVE} ) {
        $net =
          $c->model('DB::Network')
          ->search(
            { institute_id => exists $ENV{HARNESS_ACTIVE_institute_id} ? $ENV{HARNESS_ACTIVE_institute_id} : 1 } )
          ->first;
    }

    $c->detach( '/error_404', [ $c->loc('Nenhuma rede para o dominio') . ' ' . $domain . '!' ] ) unless $net;

    $c->stash->{network} = $net;

    $c->stash->{institute}  = $net->institute;
    $c->stash->{c_req_path} = $c->req->path;
}

sub load_status_msgs : Private {
    my ( $self, $c ) = @_;

    $c->load_status_msgs;
    my $status_msg = $c->stash->{status_msg};
    my $error_msg  = $c->stash->{error_msg};

    @{ $c->stash }{ keys %$status_msg } = values %$status_msg if ref $status_msg eq 'HASH';
    @{ $c->stash }{ keys %$error_msg }  = values %$error_msg  if ref $error_msg eq 'HASH';

    if ( $c->stash->{form_error} && ref $c->stash->{form_error} eq 'HASH' ) {
        my $aff = {};
        foreach ( keys %{ $c->stash->{form_error} } ) {
            my ( $hm, $fo ) = $_ =~ /(.+)\.(.+)$/;

            $aff->{$hm} = $fo;
        }
        $c->stash->{form_error} = $aff;
    }
}

sub institute_load : Chained('light_institute_load') PathPart('') CaptureArgs(0) {
    my ( $self, $c ) = @_;

    $c->stash->{institute_loaded} = 1;

    # garante que foi executado sempre o light quando o foi executado apenas o 'institute_load'
    # nos lugares que chama essa sub sem ser via $c->forward ou semelhantes
    $c->forward('light_institute_load') if !exists $c->stash->{c_req_path};

=pod
    my @inner_page;

    if (exists $c->stash->{user_obj} && ref $c->stash->{user_obj}  eq 'Iota::Model::DB::User'){
        @inner_page = (
            '-or' => [
                { 'user.city_id' => undef },
                { 'user.id' => $c->stash->{user_obj}->id }
            ]
        );
    }
=cut

    my @users = $c->stash->{network}->users->search(
        {
            active => 1,

            #        @inner_page
        },
        {
            prefetch => [ 'city', 'network_users' ]
        }
    )->all;
    $c->stash->{current_all_users} = \@users;

    my @current_admins = grep { !$_->city_id } @users;
    $c->detach( '/error_404', ['Nenhum admin de rede encontrado!'] ) unless @current_admins;
    $c->detach( '/error_404', ['Mais de um admin de rede para o dominio encontrado!'] ) if @current_admins > 1;

    my $admin = $c->stash->{current_admin_user} = $current_admins[0];

    my @files = $admin->user_files->search(
        undef,
        {
            columns => [qw/created_at class_name private_path/]
        }
    )->all;

    foreach my $file ( sort { $b->created_at->epoch <=> $a->created_at->epoch } @files ) {
        if ( $file->class_name eq 'custom.css' ) {
            my $path      = $file->private_path;
            my $path_root = $c->path_to('root');
            $path =~ s/$path_root//;

            # coloca por ultimo na ordem dos arquivos
            $c->assets->include( $path, 99999 );

            # sai do loop pra nao pegar todas as versoes do arquivo
            last;
        }
    }

    # utilizada para fazer filtro dos indicados
    # apenas para a cidade dele [o segundo parametro é ignorado]
    $c->stash->{current_city_user_id} = undef;

    my @cities = sort { $a->pais . $a->uf . $a->name cmp $b->pais . $b->uf . $b->name }
      map  { $_->city }
      grep { defined $_->city_id } @users;

    $c->stash->{current_cities} = \@cities;

    $c->stash->{network_data} = {
        states => [
            do {
                my %seen;
                grep { !$seen{$_}++ } grep { defined } map { $_->state_id } @cities;
              }
        ],
        users_ids => [
            do {
                my %seen;
                grep { !$seen{$_}++ } map { $_->id } grep { defined $_->city_id } @users;
              }
        ],

        # redes de todos os usuarios que estão na pagina.
        network_ids => [
            do {
                my %seen;
                grep { !$seen{$_}++ } map {
                    map { $_->network_id }
                      $_->network_users
                } grep { defined $_->city_id } @users;
              }
        ],

        # rede selecionada do idioma.
        network_id => [ $c->stash->{network}->id ],
        admins_ids => [ map { $_->id } grep { !defined $_->city_id } @users ],
        cities     => \@cities
    };

    my $cur_lang = exists $c->req->cookies->{cur_lang} ? $c->req->cookies->{cur_lang}->value : undef;

    if ( !defined $cur_lang ) {
        my $al = $c->req->headers->header('Accept-language');
        my $language = $self->lang_acceptor->accepts( $al, split /,/, $c->config->{available_langs} );

        $cur_lang = $language;
    }
    else {
        my %langs = map { $_ => 1 } split /,/, $c->config->{available_langs};
        $cur_lang = 'pt-br' unless exists $langs{$cur_lang};
    }

    $self->json_to_view(
        $c,
        institute_json => {
            (
                map { $_ => $c->stash->{institute}->$_ }
                  qw/
                  name
                  bypass_indicator_axis_if_custom
                  hide_empty_indicators
                  /
            )
        }
    );

    $c->set_lang($cur_lang);

    $c->response->cookies->{'cur_lang'} = {
        value   => $cur_lang,
        path    => '/',
        expires => '+3600h',
      }
      if !exists $c->req->cookies->{cur_lang} || $c->req->cookies->{cur_lang} ne $cur_lang;

}

sub erro : Chained('institute_load') PathPart('erro') Args(0) {
    my ( $self, $c ) = @_;

    $c->stash(
        custom_wrapper => 'site/iota_wrapper',
        v2             => 1,
        template       => 'error.tt'
    );
}

sub mapa_site : Chained('institute_load') PathPart('mapa-do-site') Args(0) {
    my ( $self, $c ) = @_;

    my @users_ids = @{ $c->stash->{network_data}{users_ids} };


    my @indicators = $c->model('DB::Indicator')->filter_visibilities(
        user_id      => $c->stash->{current_city_user_id},
        networks_ids => $c->stash->{network_data}{network_id},

        #users_ids    => \@users_ids,
      )->search(
        { is_fake => 0 },
        {
            order_by => 'name',
        }
      )->as_hashref->all;

    my @good_pratices = $c->model('DB::UserBestPratice')->search(
        {
            'user.active' => 1,
            'user.id'     => { '-in' => \@users_ids }
        },
        {
            select => [
                \"city.pais || '/' || city.uf || '/' || city.name_uri as user_url", \'city.name as city_name',
                \'count(1)'
            ],
            as       => [ 'user_url', 'city_name', 'count' ],
            group_by => [ 'user_url', 'city_name' ],
            join         => { 'user' => 'city' },
            result_class => 'DBIx::Class::ResultClass::HashRefInflator',
            order_by     => 'city_name'
        }
    )->all;

    $c->stash(
        cities        => $c->stash->{network_data}{cities},
        indicators    => \@indicators,
        best_pratices => \@good_pratices,
        template      => 'mapa_site.tt',
        v2 => 1,
        custom_wrapper => 'site/iota_wrapper',
    );
}

sub build_indicators_menu : Chained('institute_load') PathPart(':indicators') Args(0) {
    my ( $self, $c, $no_template ) = @_;

    my @users_ids = @{ $c->stash->{network_data}{users_ids} };

    my $show_user_private_indicators = $c->stash->{show_user_private_indicators};
    my $network_ids                  = [
        do {
            my %seen;
            grep { !$seen{$_}++ } map {
                map { $_->network_id }
                  $_->network_users
              } grep { defined $_->city_id }
              grep   { $show_user_private_indicators->{ $_->id } } @{ $c->stash->{current_all_users} };
          }
    ];

    my @indicators = $c->model('DB::Indicator')->filter_visibilities(

        $show_user_private_indicators && keys %$show_user_private_indicators
        ? (
            users_ids    => [ keys %$show_user_private_indicators ],
            networks_ids => $network_ids
          )
        : (
            user_id      => $c->stash->{current_city_user_id},
            networks_ids => $c->stash->{current_city_user_id} ? $c->stash->{network_data}{network_ids}
            : $c->stash->{network_data}{network_id},
        )
      )->search(
        {
            is_fake => 0
        },
        {
            join     => 'axis',
            collapse => 1,
            order_by => 'me.name',
            columns  => [
                qw/
                  axis.id
                  axis.name

                  me.id
                  me.name
                  me.name_url
                  me.period
                  me.explanation
                  /
            ]
        }
      )->as_hashref->all;

    my $city = $c->stash->{city};

    my $user_id = $city && $c->stash->{user} ? $c->stash->{user}{id} : undef;

    my $id_vs_group_name = {};
    my $groups           = {};
    my $group_id         = 0;

    my @custom_axis =
      $user_id
      ? $c->model('DB::UserIndicatorAxis')->search(
        {
            user_id => $user_id
        },
        {
            prefetch => 'user_indicator_axis_items'
        }
      )->as_hashref->all
      : ();

    if (@custom_axis) {
        my $ind_vs_group = {};

        foreach my $g (@custom_axis) {

            foreach ( @{ $g->{user_indicator_axis_items} } ) {
                push @{ $ind_vs_group->{ $_->{indicator_id} } }, $g->{name};
            }
        }

        for my $i (@indicators) {
            next if !exists $ind_vs_group->{ $i->{id} };

            foreach my $group_name ( @{ $ind_vs_group->{ $i->{id} } } ) {
                if ( !exists $groups->{$group_name} ) {
                    $group_id++;

                    $groups->{$group_name}         = $group_id;
                    $id_vs_group_name->{$group_id} = $group_name;
                }

                push @{ $i->{groups} }, $groups->{$group_name};
            }
        }
    }

    my $region = $c->stash->{region} ? { $c->stash->{region}->get_inflated_columns } : $c->stash->{region};

    my $selected_indicator = $c->stash->{indicator};

    my $active_group = {
        name => 'Todos os indicadores',
        id   => 0
    };

    my $institute = $c->stash->{institute};

    my $count_used_groups = {};

    for my $i (@indicators) {

        if ( !exists $groups->{ $i->{axis}{name} } ) {
            $group_id++;

            $id_vs_group_name->{$group_id} = $i->{axis}{name};
            $groups->{ $i->{axis}{name} } = $group_id;
        }

        my $group_id = $groups->{ $i->{axis}{name} };

        # se ja tem algum grupo, entao nao verifica se precisa inserir
        if ( $i->{groups} && @{ $i->{groups} } > 0 ) {
            if ( !$institute->bypass_indicator_axis_if_custom ) {
                push @{ $i->{groups} }, $group_id;
                $count_used_groups->{$group_id}++;
            }
            else {
                $count_used_groups->{$group_id} = 0 if !exists $count_used_groups->{$group_id};
            }
        }
        else {
            push @{ $i->{groups} }, $group_id;

            $count_used_groups->{$group_id}++;
        }

        if ( $selected_indicator && $selected_indicator->{id} == $i->{id} ) {
            $i->{selected} = 1;

            $active_group = {
                name => $id_vs_group_name->{ $i->{groups}[0] },
                id   => $i->{groups}[0]
            };
        }

        if ($region) {

            $i->{href} = join '/', '', $city->{pais}, $city->{uf}, $city->{name_uri}, 'regiao', $region->{name_url},
              $i->{name_url};

        }
        elsif ($city) {

            $i->{href} = join '/', '', $city->{pais}, $city->{uf}, $city->{name_uri}, $i->{name_url};

        }
        else {
            $i->{href} = '/' . $i->{name_url};
        }
    }

    # todos os $count_used_groups = 0 sao eixos (nao grupos), que nao
    # foram usados em nenhum indicador.
    while ( my ( $group_id, $count ) = each %$count_used_groups ) {
        next unless $count == 0;

        delete $groups->{ $id_vs_group_name->{$group_id} };
        delete $id_vs_group_name->{$group_id};
    }

    if ( $active_group->{id} ) {
        for my $i (@indicators) {
            $i->{visible} = ( grep { /^$active_group->{id}$/ } @{ $i->{groups} } ) ? 1 : 0;
        }
    }

    $c->stash(
        groups       => $groups,
        active_group => $active_group,
        indicators   => \@indicators,

    );

    $c->stash( template => 'list_indicators.tt' ) if !$no_template;
}

sub download_redir : Chained('root') PathPart('download') Args(0) {
    my ( $self, $c ) = @_;
    $c->res->redirect( '/dados-abertos', 301 );
}

sub download : Chained('institute_load') PathPart('dados-abertos') Args(0) {
    my ( $self, $c ) = @_;

    $self->mapa_site($c);

    $c->stash(
        title          => 'Dados abertos',
        template       => 'download.tt',
        custom_wrapper => 'site/iota_wrapper',
        v2             => 1,
    );

}

sub network_page : Chained('institute_load') PathPart('') CaptureArgs(0) {
    my ( $self, $c ) = @_;
}

sub network_pais : Chained('network_page') PathPart('') CaptureArgs(1) {
    my ( $self, $c, $sigla ) = @_;
    $c->stash->{pais} = $sigla;
}

sub network_estado : Chained('network_pais') PathPart('') CaptureArgs(1) {
    my ( $self, $c, $estado ) = @_;
    $c->stash->{estado} = $estado;
}

sub network_cidade : Chained('network_estado') PathPart('') CaptureArgs(1) {
    my ( $self, $c, $cidade ) = @_;
    $c->stash->{cidade} = $cidade;

    $c->forward('stash_tela_cidade');

    $c->stash->{title} = $c->stash->{city}{name} . ', ' . $c->stash->{city}{uf};

    $self->load_region_names($c) if $c->stash->{user}{regions_enabled};

    if ( $self->load_best_pratices( $c, only_count => 1 ) ) {
        $c->stash->{best_pratices_link} = $c->uri_for( $self->action_for('best_pratice_list'),
            [ $c->stash->{pais}, $c->stash->{estado}, $c->stash->{cidade} ] );
    }

    if (
        $c->model('DB::UserFile')->search(
            {
                user_id      => $c->stash->{user}{id},
                hide_listing => 0
            }
        )->count
      ) {
        $c->stash->{files_link} = $c->uri_for( $self->action_for('user_file_list'),
            [ $c->stash->{pais}, $c->stash->{estado}, $c->stash->{cidade} ] );
    }

}

sub load_region_names {
    my ( $self, $c ) = @_;

    my $rs = $c->model('DB::UserRegion')->search(
        {
            user_id => $c->stash->{user}{id}
        }
    )->as_hashref;

    while ( my $row = $rs->next ) {
        $c->stash->{region_classification_name}{ $row->{depth_level} } = $row->{region_classification_name};
    }

    $c->stash->{region_classification_name}{2} ||= 'Região';
    $c->stash->{region_classification_name}{3} ||= 'Subregião';

}

sub cidade_regioes : Chained('network_cidade') PathPart('regiao') Args(0) {
    my ( $self, $c ) = @_;

    $c->stash->{title}    = $c->stash->{city}{name} . ', ' . $c->stash->{city}{uf} . ' - ' . $c->loc('Regiões');
    $c->stash->{template} = 'home_cidade_region.tt';

    $c->detach( '/error_404', ['Regioes desabilitadas para este usuário!'] ) if !$c->stash->{user}{regions_enabled};
}

sub cidade_indicadores : Chained('network_cidade') PathPart('indicadores') Args(0) {
    my ( $self, $c ) = @_;

    $c->stash->{title}    = $c->stash->{city}{name} . ', ' . $c->stash->{city}{uf} . ' - ' . $c->loc('Indicadores');
    $c->stash->{template} = 'home_cidade_indicator.tt';
}

sub cidade_regiao : Chained('network_cidade') PathPart('regiao') CaptureArgs(1) {
    my ( $self, $c, $regiao ) = @_;
    $c->stash->{regiao_url} = $regiao;

    $c->detach( '/error_404', ['Regioes desabilitadas para este usuário!'] ) if !$c->stash->{user}{regions_enabled};

    $self->stash_tela_regiao($c);

    $c->stash->{title} = $c->stash->{region}->name . ' - ' . $c->stash->{city}{name} . ', ' . $c->stash->{city}{uf};
}

sub cidade_regiao_indicator : Chained('cidade_regiao') PathPart('') CaptureArgs(1) {
    my ( $self, $c, $indicator ) = @_;

    $c->stash->{indicator} = $indicator;
    $c->forward('stash_tela_indicator');

    $c->stash( template => 'home_region_indicator.tt' );

    $c->forward('stash_distritos');

    $c->forward('stash_comparacao_distritos');

    $c->forward( 'build_indicators_menu', [1] );
}

sub stash_distritos : Private {
    my ( $self, $c ) = @_;

    my $schema    = $c->model('DB');
    my $region    = $c->stash->{region};
    my $indicator = $c->stash->{indicator};
    my $user      = $c->stash->{user};

    my @fatores = $schema->resultset('ViewFatorDesigualdade')->search(
        {},
        {
            bind         => [ $region->id, $indicator->{id}, $user->{id} ],
            result_class => 'DBIx::Class::ResultClass::HashRefInflator'
        }
    )->all;

    $c->stash->{fator_desigualdade} = \@fatores;

    if ( $c->stash->{current_part} && $c->stash->{current_part} eq 'fator_desigualdade' ) {
        $c->stash(
            template        => 'parts/fator_desigualdade.tt',
            without_wrapper => 1
        );
    }
}

sub stash_comparacao_distritos : Private {
    my ( $self, $c ) = @_;

    my $schema    = $c->model('DB');
    my $region    = $c->stash->{region};
    my $indicator = $c->stash->{indicator};
    my $user      = $c->stash->{user};

    $c->stash->{color_index} = [ '#D7E7FF', '#A5DFF7', '#5A9CE8', '#0041B5', '#20007B', '#F1F174' ];

    my $polys = {};
    my $regs = {};
    foreach my $reg ( @{ $c->stash->{city}{regions} } ) {
        next unless $reg->{subregions};


        if ($region->depth_level == 2){
            $regs->{$reg->{id}} = { map { $_ => $reg->{$_} } qw/name name_url/ };

            foreach my $sub ( @{ $reg->{subregions} } ) {

                delete $sub->{polygon_path}
                    if defined $sub->{polygon_path} && $sub->{polygon_path} eq 'null';
                next unless $sub->{polygon_path};

                push @{ $polys->{ $reg->{id} } }, $sub->{polygon_path};
            }
        }elsif ($region->depth_level == 3){

            foreach my $sub ( @{ $reg->{subregions} } ) {
                $regs->{$sub->{id}} = { map { $_ => $sub->{$_} } qw/name name_url/ };

                push @{ $polys->{ $sub->{id} } }, $sub->{polygon_path};
            }


        }
    }

    my $valor_rs = $schema->resultset('ViewValuesRegion')->search(
        {},
        {
            bind =>
              [ $region->depth_level, $region->id, $user->{id}, $indicator->{id}, $user->{id}, $indicator->{id}, ],
            result_class => 'DBIx::Class::ResultClass::HashRefInflator'
        }
    );
    my $por_ano = {};

    while ( my $r = $valor_rs->next ) {
        $r->{variation_name} ||= '';

        push @{ $por_ano->{ delete $r->{valid_from} }{ delete $r->{variation_name} } }, $r;
    }
    my $freq = Iota::Statistics::Frequency->new();

    my $out = {};
    while ( my ( $ano, $variacoes ) = each %$por_ano ) {
        while ( my ( $variacao, $distintos ) = each %$variacoes ) {

            my $distintos_ref_id = {map {$_->{id} => $_ } @$distintos};

            my $stat = $freq->iterate($distintos);

            my $definidos = [ grep { defined $_->{num} } @$distintos ];

            # melhor = mais alto, entao inverte as cores
            if ( !$indicator->{sort_direction} || $indicator->{sort_direction} eq 'greater value' ) {
                $_->{i} = 4 - $_->{i} for @$definidos;
                $distintos =
                  [ ( reverse grep { defined $_->{num} } @$distintos ), grep { !defined $_->{num} } @$distintos ];
                $definidos = [ reverse @$definidos ];
            }

            if ($stat) {
                $out->{$ano}{$variacao} = {
                    all    => $distintos,
                    top3   => [ $definidos->[0], $definidos->[1], $definidos->[2], ],
                    lower3 => [ $definidos->[-3], $definidos->[-2], $definidos->[-1] ],
                    mean   => $stat->mean()
                };
            }
            elsif ( @$definidos == 4 ) {
                $definidos->[0]{i} = 0;    # Alta / Melhor
                $definidos->[1]{i} = 1;    # acima media
                $definidos->[2]{i} = 3;    # abaixo da media
                $definidos->[3]{i} = 4;    # Baixa / Pior
            }
            elsif ( @$definidos == 3 ) {
                $definidos->[0]{i} = 0;    # Alta / Melhor
                $definidos->[1]{i} = 2;    # média
                $definidos->[2]{i} = 4;    # Baixa / Pior
            }
            elsif ( @$definidos == 2 ) {
                $definidos->[0]{i} = 0;    # Alta / Melhor
                $definidos->[1]{i} = 4;    # Baixa / Pior
            }
            else {
                $_->{i} = 5 for @$definidos;
            }

            $out->{$ano}{$variacao} = { all => $distintos }
              unless exists $out->{$ano}{$variacao};


            foreach my $region_id (keys %$regs){

                unless (exists $distintos_ref_id->{$region_id}){
                    $distintos_ref_id->{$region_id} = {};
                    push @$distintos, $distintos_ref_id->{$region_id};
                }

                $distintos_ref_id->{$region_id}{polygon_path} = $polys->{$region_id};
                $distintos_ref_id->{$region_id}{$_} = $regs->{$region_id}{$_} for keys %{$regs->{$region_id}};

            }


            my @nao_definidos = grep { !defined $_->{num} } @$distintos;
            for (@nao_definidos) {
                $_->{i}   = 5;             # amarelo/sem valor
                $_->{num} = 'n/d';
            }
            push @$definidos, @nao_definidos;
        }
    }

    $c->stash->{analise_comparativa} = $out;

    if ( $c->stash->{current_part} && $c->stash->{current_part} eq 'analise_comparativa' ) {
        $c->stash(
            template        => 'parts/analise_comparativa.tt',
            without_wrapper => 1
        );
    }
}

sub cidade_regiao_indicator_render : Chained('cidade_regiao_indicator') PathPart('') Args(0) {
}

sub cidade_regiao_render : Chained('cidade_regiao') PathPart('') Args(0) {
}

sub network_render : Chained('network_cidade') PathPart('') Args(0) {
}

sub user_page : Chained('network_cidade') PathPart('pagina') CaptureArgs(2) {
    my ( $self, $c, $page_id, $title ) = @_;

    my $page = $c->model('DB::UserPage')->search(
        {
            id      => $page_id,
            user_id => $c->stash->{user}{id}
        }
    )->as_hashref->next;

    $c->detach('/error_404') unless $page;
    $c->stash->{page} = $page;

    $c->stash(
        template => 'home_cidade_pagina.tt',
        title    => $page->{title}
    );

}

sub user_page_render : Chained('user_page') PathPart('') Args(0) {
    my ( $self, $c ) = @_;
}

sub best_pratice : Chained('network_cidade') PathPart('boa-pratica') CaptureArgs(2) {
    my ( $self, $c, $page_id, $title ) = @_;

    $self->load_best_pratices($c);

    my $page = $c->model('DB::UserBestPratice')->search(
        {
            'me.id'      => $page_id,
            'me.user_id' => $c->stash->{user}{id}
        },
        { prefetch => [ 'axis', { user_best_pratice_axes => 'axis' } ] }
    )->as_hashref->next;

    $c->detach('/error_404') unless $page;
    $c->stash->{best_pratice} = $page;

    $c->stash(
        template => 'home_cidade_boas_praticas.tt',
        title    => $page->{name}
    );

}

sub load_best_pratices {
    my ( $self, $c, %flags ) = @_;

    my $rs =
      $c->model('DB::UserBestPratice')->search( { user_id => $c->stash->{user}{id} }, { prefetch => 'axis' } )
      ->as_hashref;

    return $rs->count if exists $flags{only_count};

    my $out;
    while ( my $obj = $rs->next ) {
        push @{ $out->{ $obj->{axis}{name} } }, $obj;

        $obj->{link} = $c->uri_for( $self->action_for('best_pratice_render'),
            [ $c->stash->{pais}, $c->stash->{estado}, $c->stash->{cidade}, $obj->{id}, $obj->{name_url}, ] );
    }
    $c->stash->{best_pratices} = $out;
}

sub best_pratice_list : Chained('network_cidade') PathPart('boas-praticas') Args(0) {
    my ( $self, $c ) = @_;
    $self->load_best_pratices($c);
    $c->stash(
        template => 'home_cidade_boas_praticas_list.tt',
        title    => 'Boas Praticas de ' . $c->stash->{city}{name} . '/' . $c->stash->{estado}
    );
}

sub load_files {
    my ( $self, $c ) = @_;

    my $rs = $c->model('DB::UserFile')->search(
        {
            user_id      => $c->stash->{user}{id},
            hide_listing => 0
        },
        {
            order_by => [ 'class_name', 'public_name' ]
        }
    );

    my $out;
    while ( my $obj = $rs->next ) {
        push @{ $out->{ $obj->{class_name} } }, $obj;
    }
    $c->stash->{files} = $out;
}

sub user_file_list : Chained('network_cidade') PathPart('arquivos') Args(0) {
    my ( $self, $c ) = @_;
    $self->load_files($c);
    $c->stash(
        template => 'home_cidade_file_list.tt',
        title    => 'Lista de arquivos de ' . $c->stash->{city}{name} . '/' . $c->stash->{estado}
    );
}

sub best_pratice_render : Chained('best_pratice') PathPart('') Args(0) {
    my ( $self, $c ) = @_;
}

sub network_indicator : Chained('network_cidade') PathPart('') CaptureArgs(1) {
    my ( $self, $c, $indicator ) = @_;
    $c->stash->{indicator} = $indicator;
    $c->forward('stash_tela_indicator');

    $c->forward( 'build_indicators_menu', [1] );
}

sub network_indicator_render : Chained('network_indicator') PathPart('') Args(0) {
    my ( $self, $c ) = @_;

    $self->_load_user_justification_of_missing_field($c);

    $c->stash( template => 'home_indicador.tt' );
}

sub _load_user_justification_of_missing_field {
    my ( $self, $c ) = @_;

    my $indicator = $c->stash->{indicator};
    my $city      = $c->stash->{city};
    my $user      = $c->stash->{user};

    my @justifications = $c->model('DB::UserIndicator')->search(
        {
            user_id      => $user->{id},
            indicator_id => $indicator->{id},
            region_id    => undef,
            '-and'       => [
                { justification_of_missing_field => { '!=' => undef } },
                { justification_of_missing_field => { '!=' => '' } },
            ]
        },
        {
            order_by => ['valid_from']
        }
    )->all;

    $c->stash->{justifications} = \@justifications;

}

sub home_network_indicator : Chained('institute_load') PathPart('') CaptureArgs(1) {
    my ( $self, $c, $nome ) = @_;

    $self->stash_indicator( $c, $nome );

    $self->stash_comparacao_cidades($c);

    $c->stash->{indicator} = { $c->stash->{indicator}->get_inflated_columns };

    $c->stash->{indicator}{created_at} = $c->stash->{indicator}{created_at}->datetime;

    $self->json_to_view( $c, indicator_json => $c->stash->{indicator} );

    if ( $c->stash->{current_part} && $c->stash->{current_part} =~ /^(comparacao_indicador_por_cidade)$/ ) {
        $c->stash(
            template        => "parts/$1.tt",
            without_wrapper => 1
        );
    }

    $c->forward( 'build_indicators_menu', [1] );
}

sub home_network_indicator_render : Chained('home_network_indicator') PathPart('') Args(0) {
}

sub stash_indicator {
    my ( $self, $c, $nome ) = @_;

    my $indicator = $c->model('DB::Indicator')->search( { name_url => $nome } )->next;

    $c->detach('/error_404') unless $indicator;
    $c->stash->{indicator} = $indicator;

    $c->stash(
        template => 'home_comparacao_indicador.tt',
        title    => 'Dados do indicador ' . $indicator->name
    );
}

use Graphics::Color::RGB;
use Chart::Clicker::Drawing::ColorAllocator;

sub web_load_country : Private {
    my ( $self, $c ) = @_;

    $c->stash->{network_data}{countries} = [
        do {
            my %seen;
            grep { !$seen{$_}++ } grep { defined } map { $_->country_id } @{ $c->stash->{current_cities} };
          }
    ];

    my @countries = $c->model('DB::Country')->search(
        {
            'me.id'     => { 'in' => $c->stash->{network_data}{countries} },
            'states.id' => { 'in' => $c->stash->{network_data}{states} }
        },
        {
            prefetch => 'states'
        }
    )->all;

    for ( @{ $c->stash->{current_cities} } ) {
        next unless defined $_->country_id && defined $_->state_id;
        push @{ $c->stash->{web}{cities_by_state}{ $_->country_id }{ $_->state_id } }, $_;
    }

    my $ca = Chart::Clicker::Drawing::ColorAllocator->new;

    foreach my $country ( sort { $a->name cmp $b->name } @countries ) {

        push @{ $c->stash->{web}{countries} }, {
            ( map { $_ => $country->$_ } qw/id name name_url/ ),

            states => [
                map { { id => $_->id, name => $_->name, uf => $_->uf } }

                  #sort { $a->name cmp $b->name } $country->states
                  sort {
                    @{ $c->stash->{web}{cities_by_state}{ $country->id }{ $b->id } }
                      <=> @{ $c->stash->{web}{cities_by_state}{ $country->id }{ $a->id } }
                  } $country->states
            ],

            color => $ca->next->as_hex_string
        };
    }

}

sub stash_comparacao_cidades {
    my ( $self, $c ) = @_;

    $self->_add_default_periods($c);

    my $controller = $c->controller('API::Indicator::Chart');
    $controller->typify( $c, 'period_axis' );

    my $indicator = $c->stash->{indicator};

    # como $c->stash->{network_data}{users_ids} esta carregado com todos os
    # usuarios da rede, temos que filtrar apenas os que fazem
    # parte deste indicador, logo:

    # se nao for publico...
    if ( $indicator->visibility_level ne 'public' ) {
        my @ids = @{ $c->stash->{network_data}{users_ids} };

        if ( $indicator->visibility_level eq 'private' ) {

            @ids = grep { $indicator->visibility_user_id } @ids;

        }
        elsif ( $indicator->visibility_level eq 'restrict' ) {

            my %fine = map { $_->user_id => 1 } $indicator->indicator_user_visibilities;
            @ids = grep { exists $fine{$_} } @ids;

        }
        elsif ( $indicator->visibility_level eq 'network' ) {

            my @nets = $indicator->indicator_network_visibilities->search(
                undef,
                {
                    prefetch     => { 'network' => 'network_users' },
                    result_class => 'DBIx::Class::ResultClass::HashRefInflator'
                }
            )->all;

            my %fine;
            map { $fine{ $_->{user_id} } = 1 } @{ $_->{network}{network_users} } for @nets;

            @ids = grep { exists $fine{$_} } @ids;

        }
        else {
            die "hey, you don't created " . $indicator->visibility_level . " permissions check yet!";
        }

        $c->stash->{network_data}{users_ids} = \@ids;
    }

    $c->stash->{user_id} = $c->stash->{network_data}{users_ids};

    $controller->render_GET($c);

    my $users = $c->stash->{rest}{users};
    foreach my $user_id ( keys %$users ) {

        $users->{$user_id}{user_id} = $user_id;
        if ( !exists $users->{$user_id}{city} ) {
            delete $users->{$user_id};
            next;
        }

        next unless ( exists $users->{$user_id}{data}{series} );

        my $series = $users->{$user_id}{data}{series};
        foreach my $serie (@$series) {
            $users->{$user_id}{by_period}{ $serie->{begin} } = $serie;
        }
    }

    $users = [ map { $users->{$_} } sort { $users->{$a}{city}{name} cmp $users->{$b}{city}{name} } keys %$users ];
    $c->stash->{users_series} = $users;

    if ( $c->stash->{indicator}->indicator_type eq 'varied' ) {
        my %all_variations;
        foreach my $user (@$users) {
            next unless exists $user->{by_period};

            # a ordem e nome das variacoes de qualquer "series" são sempre
            # as mesmas.
            $user->{variations} = [ map { $_->{name} } @{ $user->{data}{series}[0]{variations} } ];

            # agora precisa correr todas as variacoes e colocar chave=>valor
            # pra ficar mais simples de acessar pela view.
            foreach my $cur_serie ( @{ $user->{data}{series} } ) {
                do {
                    $all_variations{ $_->{name} } = 1;
                    $cur_serie->{by_variation}{ $_->{name} } = $_;
                  }
                  for ( @{ $cur_serie->{variations} } );
            }
        }

        $c->stash->{all_variations} = [ sort keys %all_variations ];
    }

    my $dados_mapa = {};

    foreach my $user (@$users) {
        next unless exists $user->{by_period};

        foreach my $valid ( keys %{ $user->{by_period} } ) {
            push @{ $dados_mapa->{$valid} },
              {
                val => $user->{by_period}{$valid}{avg},
                lat => $user->{city}{latitude},
                lng => $user->{city}{longitude},
                nm  => $user->{city}{name},
              };
        }
    }

    $self->json_to_view( $c, dados_mapa_json => $dados_mapa );

    my $dados_grafico = { dados => [] };
    foreach my $period ( @{ $c->stash->{choosen_periods}[2] } ) {
        push @{ $dados_grafico->{labels} },
          Iota::IndicatorChart::PeriodAxis::get_label_of_period( $period, $c->stash->{indicator}->period );
    }

    my %shown = exists $c->req->params->{graphs} ? map { $_ => 1 } split '-', $c->req->params->{graphs} : ();

    $c->stash->{show_user_private_indicators} = \%shown;

    foreach my $user ( @{ $c->stash->{users_series} } ) {
        next unless exists $user->{by_period};

        my $user_id = $user->{user_id};

        my $reg_user = {
            show => exists $shown{$user_id} ? 1 : 0,
            id   => $user_id,
            nome => $user->{city}{name},
            valores => []
        };

        my $idx = 0;
        foreach my $period ( @{ $c->stash->{choosen_periods}[2] } ) {

            if ( exists $user->{by_period}{$period} ) {
                $reg_user->{valores}[$idx] = $user->{by_period}{$period}{avg};
            }
            $idx++;
        }
        push @{ $dados_grafico->{dados} }, $reg_user;
    }

    $self->json_to_view( $c, dados_grafico_json => $dados_grafico );

    $c->stash->{current_tab} =
      exists $c->req->params->{view}
      ? $c->req->params->{view}
      : 'table';
}

sub json_to_view {
    my ( $self, $c, $st, $obj ) = @_;

    $c->stash->{$st} = JSON::XS->new->utf8(0)->encode($obj);
}

sub _add_default_periods {
    my ( $self, $c ) = @_;

    my $data_atual   = DateTime->now;
    my $ano_anterior = $data_atual->year() - 1;

    my $grupos      = 4;
    my $step        = 4;
    my $ano_inicial = $ano_anterior - ( $grupos * $step ) + 1;

    my @periods;

    my $cont = 0;
    my $ant;
    my @loop;
    for my $i ( $ano_inicial .. $ano_anterior ) {
        push @loop, "$i-01-01";
        if ( $cont == 0 ) {
            $ant = "$i-01-01";
        }
        elsif ( $cont == $step - 1 ) {
            push @periods, [ $ant, "$i-01-01", [@loop], $c->req->uri_with( { valid_from => $ant } )->as_string ];
            undef @loop;
            $cont = -1;
        }

        $cont++;
    }
    $c->stash->{data_periods} = \@periods;

    $c->req->params->{valid_from} =
      exists $c->req->params->{valid_from}
      ? $c->req->params->{valid_from}
      : $periods[-1][0];

    my $ativo = undef;

    my $i = 0;
  PROCURA: foreach my $grupo (@periods) {

        foreach my $periodo ( @{ $grupo->[2] } ) {
            if ( $periodo eq $c->req->params->{valid_from} ) {
                $ativo = $i;
                last PROCURA;
            }
        }
        $i++;
    }

    if ( defined $ativo ) {
        $c->req->params->{from}      = $periods[$ativo][0];
        $c->req->params->{to}        = $periods[$ativo][1];
        $c->stash->{choosen_periods} = $periods[$ativo];
    }
    else {
        $c->req->params->{from}      = $periods[-1][0];
        $c->req->params->{to}        = $periods[-1][1];
        $c->stash->{choosen_periods} = $periods[-1];
    }

}

sub stash_tela_indicator : Private {
    my ( $self, $c ) = @_;

    # carrega a cidade/user
    $c->forward('stash_tela_cidade');

    # anti bug de quem chamar isso sem ler o fonte ^^
    delete $c->stash->{template};

    my $show_user_private_indicators = $c->stash->{show_user_private_indicators} =
      { $c->stash->{current_city_user_id} => 1 };

    my $network_ids = [
        do {
            my %seen;
            grep { !$seen{$_}++ } map {
                map { $_->network_id }
                  $_->network_users
              } grep { defined $_->city_id }
              grep   { $show_user_private_indicators->{ $_->id } } @{ $c->stash->{current_all_users} };
          }
    ];

    my $indicator = $c->model('DB::Indicator')->filter_visibilities(
        user_id      => $c->stash->{current_city_user_id},
        networks_ids => $network_ids,

        #users_ids    => \@users_ids,
      )->search(
        {
            name_url => $c->stash->{indicator},
        },
      )->as_hashref->next;
    $c->detach( '/error_404', ['Indicador não encontrado!'] ) unless $indicator;

    $c->stash->{indicator} = $indicator;

    $c->stash->{title} = $indicator->{name} . ' de ' . $c->stash->{city}{name} . ', ' . $c->stash->{city}{uf};
}

sub stash_tela_cidade : Private {
    my ( $self, $c ) = @_;

    my $city = $c->model('DB::City')->search(
        {
            'me.pais'     => lc $c->stash->{pais},
            'me.uf'       => uc $c->stash->{estado},
            'me.name_uri' => lc $c->stash->{cidade}
        },
        {
            prefetch => [ { 'state' => 'country' } ]
        }
    )->as_hashref->next;

    $c->detach('/error_404') unless $city;

    my $user = $c->model('DB::User')->search(
        {
            city_id                    => $city->{id},
            'me.active'                => 1,
            'network_users.network_id' => $c->stash->{network}->id
        },
        { join => 'network_users' }
    )->next;
    $c->detach('/error_404') unless $user;

    $c->stash->{current_city_user_id} = $user->id;

    if ( $user->regions_enabled ) {
        $city->{regions} = [
            $c->model('DB::Region')->search(
                {
                    city_id => $city->{id}
                }
            )->as_hashref->all
        ];
    }

    $self->_setup_regions_level( $c, $city ) if ( $city->{regions} && @{ $city->{regions} } > 0 );

    $c->detach('/error_404') unless $user;

    $c->stash->{user_obj} = $user;
    my $public = $c->controller('API::UserPublic')->user_public_load($c);
    $c->stash( public => $public );

    my @files = $user->user_files->search(
        undef,
        {
            columns => [qw/private_path created_at class_name/]
        }
    )->all;

    foreach my $file ( sort { $b->created_at->epoch <=> $a->created_at->epoch } @files ) {
        if ( $file->class_name eq 'custom.css' ) {

            my $path      = $file->private_path;
            my $path_root = $c->path_to('root');
            $path =~ s/$path_root//;
            $c->assets->include( $path, 99999 );

            last;
        }
    }

    my $menurs = $user->user_menus->search(
        undef,
        {
            order_by => [ { '-asc' => 'me.position' }, 'me.id' ],
            prefetch => 'page'
        }
    );
    $self->_load_menu( $c, $menurs );

    $self->_load_variables( $c, $user );

    $user = { $user->get_inflated_columns };
    $c->stash(
        city     => $city,
        user     => $user,
        template => 'home_cidade.tt',
    );
}

sub _setup_regions_level {
    my ( $self, $c, $city ) = @_;

    my $out = {};
    foreach my $reg ( @{ $city->{regions} } ) {
        my $x = $reg->{upper_region} || $reg->{id};
        push @{ $out->{$x} }, $reg;
    }

    my @regions;
    foreach my $id ( keys %$out ) {
        my $pai;
        my @subs;
        foreach my $r ( @{ $out->{$id} } ) {
            $r->{url} = $c->uri_for( $self->action_for('cidade_regiao_render'),
                [ $city->{pais}, $city->{uf}, $city->{name_uri}, $r->{name_url} ] )->as_string;

            if ( !$r->{upper_region} ) {
                $pai = $r;
            }
            else {
                push @subs, $r;
            }
        }
        $pai->{subregions} = \@subs;
        push @regions, $pai;
    }

    $city->{regions} = \@regions;
}

sub _load_variables {
    my ( $self, $c, $user ) = @_;

    my $mid = $user->id;

    my $var_confrs =
      $c->model('DB::UserVariableConfig')->search( { user_id => [ $c->stash->{network_data}{admins_ids}, $mid ] } );
    my $aux = {};
    while ( my $conf = $var_confrs->next ) {
        push @{ $aux->{ $conf->variable_id } }, [ $conf->display_in_home, $conf->user_id, $conf->position ];
    }

    my $show  = {};
    my $order = {};

    while ( my ( $vid, $wants ) = each %$aux ) {

        foreach my $conf (@$wants) {

            # a configuracao do usuario sempre tem preferencia sob a do admin
            if ( $conf->[1] == $mid ) {
                $order->{$vid} = $conf->[2];
                $show->{$vid}  = $conf->[0];
                last;
            }
            elsif ( $conf->[0] && !exists $show->{$vid} ) {
                $order->{$vid} = $conf->[2];
                $show->{$vid}++;
            }
        }

    }
    $show = { map { $show->{$_} ? ( $_ => 1 ) : () } keys %$show };

    my $values = $user->variable_values->search(
        { variable_id => { 'in' => [ keys %$show ] }, },
        {
            order_by => [            { -desc => 'valid_from' } ],
            prefetch => { 'variable' => 'measurement_unit' }
        }
    );

    my %exists;
    my @variables;
    while ( my $val = $values->next ) {
        next if $exists{ $val->variable_id }++;

        push @variables, $val;
    }

    @variables = sort { $order->{ $a->variable_id } <=> $order->{ $b->variable_id } } @variables;

    $c->stash( user_basic_variables => \@variables );
}

sub _load_menu {
    my ( $self, $c, $menurs ) = @_;

    my $menu = {};
    my @menu_out;

    while ( my $m = $menurs->next ) {
        my $pai = $m->menu_id || $m->id;
        push( @{ $menu->{$pai} }, $m );
    }

    while ( my ( $id, $rows ) = each %$menu ) {
        my $menu;
        for my $menurs (@$rows) {
            if ( !$menurs->menu_id ) {
                $menu = {
                    title => $menurs->title,
                    (
                        link => $menurs->page_id
                        ? $c->uri_for(
                            $self->action_for('user_page_render'),
                            [
                                $c->stash->{pais}, $c->stash->{estado}, $c->stash->{cidade},
                                $menurs->page_id,  $menurs->page->title_url,
                            ]
                          )
                        : ''
                    )
                };
                push @menu_out, $menu;
            }
        }

        for my $menurs (@$rows) {
            if ( $menurs->menu_id ) {
                push @{ $menu->{subs} },
                  {
                    title => $menurs->title,
                    (
                        link => $menurs->page_id
                        ? $c->uri_for(
                            $self->action_for('user_page_render'),
                            [
                                $c->stash->{pais}, $c->stash->{estado}, $c->stash->{cidade},
                                $menurs->page_id,  $menurs->page->title_url,
                            ]
                          )
                        : ''
                    )
                  };
            }
        }
    }

    $c->stash( menu => \@menu_out, );

}

sub stash_tela_regiao {
    my ( $self, $c ) = @_;

    my $region = $c->model('DB::Region')->search(
        {
            name_url => lc $c->stash->{regiao_url},
            city_id  => $c->stash->{city}{id}
        }
    )->next;

    $c->detach('/error_404') unless $region;
    $c->stash(
        region   => $region,
        template => 'home_region.tt',
    );

    if ( $region->depth_level == 2 ) {
        my @subregions = $c->model('DB::Region')->search(
            {
                city_id      => $c->stash->{city}{id},
                upper_region => $region->id
            }
        )->all;
        $c->stash->{subregions} = \@subregions;
    }

    $self->_load_region_variables($c);
}

sub _load_region_variables {
    my ( $self, $c ) = @_;

    my $region = $c->stash->{region};

    my $mid = $c->stash->{user}{id};
    my $var_confrs =
      $region->user_variable_region_configs->search( { user_id => [ $c->stash->{network_data}{admins_ids}, $mid ] } );

    my $aux = {};
    while ( my $conf = $var_confrs->next ) {
        push @{ $aux->{ $conf->variable_id } }, [ $conf->display_in_home, $conf->user_id, $conf->position ];
    }

    my $show  = {};
    my $order = {};

    # a configuracao do usuario sempre tem preferencia sob a do admin
    while ( my ( $vid, $wants ) = each %$aux ) {

        if ( @$wants == 1 && $wants->[0][0] ) {
            $order->{$vid} = $wants->[0][2];
            $show->{$vid}++ and last;
        }

        foreach my $conf (@$wants) {
            if ( $conf->[1] == $mid && $conf->[0] ) {

                $order->{$vid} = $conf->[2];
                $show->{$vid}++ and last;
            }
        }

    }
    my $active_value = exists $c->req->params->{active_value} ? $c->req->params->{active_value} : 1;
    my $values = $region->region_variable_values->search(
        {
            'me.variable_id'  => { 'in' => [ keys %$show ] },
            'me.user_id'      => $mid,
            'me.active_value' => $active_value
        },
        {
            order_by => [            { -desc => 'me.valid_from' } ],
            prefetch => { 'variable' => 'measurement_unit' }
        }
    );

    my %exists;
    my @variables;
    while ( my $val = $values->next ) {
        next if $exists{ $val->variable_id }++;

        push @variables, $val;
    }

    @variables = sort { $order->{ $a->variable_id } <=> $order->{ $b->variable_id } } @variables;

    $c->stash( basic_variables => \@variables );

}

__PACKAGE__->meta->make_immutable;

1;
